import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

const ids = {
  tenant: "10000000-0000-0000-0000-000000000001",
  other: "10000000-0000-0000-0000-000000000002",
  admin: "10000000-0000-0000-0000-000000000003",
  agent: "10000000-0000-0000-0000-000000000004",
  secondAdmin: "10000000-0000-0000-0000-000000000005",
  outsider: "10000000-0000-0000-0000-000000000006",
};
const migrations = new URL("../migrations/", import.meta.url);

Deno.test("tenant user management enforces scope, roles, active access and last administrator", async () => {
  const db = new PGlite();
  const sql = (query: string, values: unknown[] = []) =>
    db.query<Record<string, unknown>>(query, values);
  const login = async (id: string) => {
    await db.exec("reset role");
    await sql("select set_config('request.jwt.claim.sub', $1, false)", [id]);
    await db.exec("set role authenticated");
  };
  const update = (tenantId: string, userId: string, role: string, active: boolean, oldRole: string, oldActive: boolean) =>
    sql("select update_tenant_user($1,$2,$3,$4,$5,$6)",
      [tenantId, userId, role, active, oldRole, oldActive]);
  const list = (tenantId: string) => sql("select * from list_tenant_users($1)", [tenantId]);
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      grant usage on schema auth to authenticated;
      create table auth.users(
        id uuid primary key, email text, banned_until timestamptz, last_sign_in_at timestamptz
      );
      create function auth.uid() returns uuid language sql as
        'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
      create schema storage;
      create table storage.objects(id uuid, bucket_id text, name text);
      alter table storage.objects enable row level security;
      grant usage on schema storage to authenticated;
      grant select, insert, update, delete on storage.objects to authenticated;
      create policy "public logo reads" on storage.objects for select using (bucket_id='tenant-logos');
      create policy "legacy logo mutations" on storage.objects for all to authenticated
        using (true) with check (true);
      create function storage.foldername(text) returns text[] language sql as
        'select string_to_array($1, ''/'')';
      create table public.user_profiles(user_id uuid primary key, full_name text, avatar_url text);
    `);
    for (const migration of [
      "20260923162000_tenant_foundation.sql",
      "20260923163000_fix_membership_rls_recursion.sql",
      "20260923163500_grant_tenant_read_access.sql",
      "20260923170500_limit_mvp_tenant_roles.sql",
      "20260923171500_platform_access_model.sql",
      "20260923172000_platform_owner_scope.sql",
      "20260923190000_platform_admin_user_access.sql",
      "20260923200000_whatsapp_inbox.sql",
      "20260923231500_tenant_integrations.sql",
      "20260924193000_notifications_and_api_integrations.sql",
    ]) await db.exec(await Deno.readTextFile(new URL(migration, migrations)));
    await db.exec(`
      insert into tenants(id,name,slug) values
        ('${ids.tenant}','Empresa Uno','uno'),('${ids.other}','Empresa Dos','dos');
      insert into auth.users(id,email,last_sign_in_at) values
        ('${ids.admin}','admin@example.test',now()),
        ('${ids.agent}','agent@example.test',now()),
        ('${ids.secondAdmin}','second@example.test',now()),
        ('${ids.outsider}','other@example.test',now());
      insert into tenant_memberships(tenant_id,user_id,role) values
        ('${ids.tenant}','${ids.admin}','tenant_admin'),
        ('${ids.tenant}','${ids.secondAdmin}','tenant_admin'),
        ('${ids.tenant}','${ids.agent}','operator'),
        ('${ids.other}','${ids.agent}','operator'),
        ('${ids.other}','${ids.outsider}','tenant_admin');
      insert into whatsapp_contacts(tenant_id,phone_number) values ('${ids.tenant}','100'),('${ids.other}','200');
      grant usage on schema public to authenticated;
    `);
    await db.exec(await Deno.readTextFile(new URL("20261106150000_tenant_user_management.sql", migrations)));
    await login(ids.admin);
    assert.equal((await list(ids.tenant)).rows.length, 3);
    await sql("insert into storage.objects(bucket_id,name) values('tenant-logos',$1)", [`${ids.tenant}/logo.png`]);
    await assert.rejects(list(ids.other), /administrador activo/);
    await assert.rejects(update(ids.tenant, ids.admin, "operator", false, "tenant_admin", true), /propio rol/);
    await assert.rejects(update(ids.tenant, ids.outsider, "operator", false, "tenant_admin", true), /ya no pertenece/);
    await assert.rejects(update(ids.tenant, ids.agent, "platform_owner", true, "operator", true), /no valido/);
    await update(ids.tenant, ids.agent, "supervisor", true, "operator", true);
    await assert.rejects(update(ids.tenant, ids.agent, "operator", true, "operator", true), /acceso cambio/);
    await update(ids.tenant, ids.agent, "supervisor", false, "supervisor", true);

    await login(ids.agent);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, null);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.other])).rows[0].role, "operator");
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 1);
    assert.equal((await sql("select * from tenants")).rows.length, 1);
    await assert.rejects(list(ids.tenant), /administrador activo/);
    await assert.rejects(list(ids.other), /administrador activo/);
    await assert.rejects(update(ids.tenant, ids.admin, "operator", false, "tenant_admin", true), /administrador activo/);
    await assert.rejects(sql("update tenant_memberships set is_active=true"), /permission denied/);
    assert.equal((await sql("select * from storage.objects")).rows.length, 1);
    await assert.rejects(sql("insert into storage.objects(bucket_id,name) values('tenant-logos',$1)",
      [`${ids.tenant}/blocked.png`]), /row-level security/);
    assert.equal((await sql("delete from storage.objects returning name")).rows.length, 0);
    await assert.rejects(sql("insert into tenant_integrations(tenant_id,provider) values($1,'whatsapp')",
      [ids.tenant]), /row-level security/);

    await login(ids.admin);
    await update(ids.tenant, ids.agent, "operator", true, "supervisor", false);
    await login(ids.agent);
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 2);
    await assert.rejects(list(ids.tenant), /administrador activo/);

    await db.exec("reset role");
    await sql("update auth.users set banned_until=now()+interval '1 day' where id=$1", [ids.agent]);
    await login(ids.agent);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.other])).rows[0].role, null);
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 0);

    await db.exec("reset role");
    await sql("update tenant_memberships set role='operator' where tenant_id=$1 and user_id=$2", [ids.tenant, ids.secondAdmin]);
    await assert.rejects(sql("update tenant_memberships set is_active=false where tenant_id=$1 and user_id=$2",
      [ids.tenant, ids.admin]), /al menos un administrador/);
    await assert.rejects(sql("delete from tenant_memberships where tenant_id=$1 and user_id=$2",
      [ids.tenant, ids.admin]), /al menos un administrador/);

    await sql("insert into platform_memberships(user_id,role) values($1,'platform_support')", [ids.outsider]);
    await login(ids.outsider);
    assert.equal((await sql("select * from tenants")).rows.length, 2);
    await assert.rejects(list(ids.tenant), /administrador activo/);
    await db.exec("reset role");
    await sql("update platform_memberships set role='platform_owner' where user_id=$1", [ids.outsider]);
    await login(ids.outsider);
    assert.equal((await list(ids.tenant)).rows.length, 3);
    await db.exec("reset role");

    // Platform grants cannot override a tenant membership explicitly disabled.
    await sql("insert into platform_tenant_grants(platform_user_id,tenant_id,tenant_role) values($1,$2,'tenant_admin')",
      [ids.agent, ids.tenant]);
    await sql("update auth.users set banned_until=null where id=$1", [ids.agent]);
    await sql("update tenant_memberships set is_active=false where tenant_id=$1 and user_id=$2", [ids.tenant, ids.agent]);
    await login(ids.agent);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, null);
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 1);
    await db.exec("reset role");
    await sql("delete from tenant_memberships where tenant_id=$1 and user_id=$2", [ids.tenant, ids.agent]);
    await login(ids.agent);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, "tenant_admin");
    await db.exec("reset role; set role anon");
    await assert.rejects(list(ids.tenant), /permission denied/);
  } finally {
    await db.close();
  }
});
