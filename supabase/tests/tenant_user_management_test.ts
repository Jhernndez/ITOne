import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";
import { compare, hash } from "npm:bcryptjs@3.0.3";

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
        id uuid primary key, email text, banned_until timestamptz, last_sign_in_at timestamptz,
        raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}',
        encrypted_password text, updated_at timestamptz
      );
      create function auth.uid() returns uuid language sql as
        'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
      create table auth.sessions(id uuid primary key, user_id uuid);
      create table auth.refresh_tokens(user_id text);
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
    await db.exec("reset role");
    const testAccountEditing = async (newId: string) => {
    await db.exec("reset role");
    await db.exec(await Deno.readTextFile(new URL("20261106170000_edit_tenant_user_accounts.sql", migrations)));
    const account = (actor: string, target: string, name: string, expected: string, passwordHash: string | null = null) =>
      sql("select update_tenant_user_account($1,$2,$3,$4,$5,$6)",
        [actor, ids.tenant, target, name, expected, passwordHash]);
    // Both active and inactive memberships in another company make it shared.
    await sql("insert into tenant_memberships(tenant_id,user_id,role,is_active) values($1,$2,'operator',false)", [ids.other, newId]);
    await db.exec("set role service_role");
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nuevo Agente"), /Cuenta compartida/);
    await db.exec("reset role");
    await sql("delete from tenant_memberships where user_id=$1 and tenant_id=$2", [newId, ids.other]);
    await login(ids.admin);
    const listed = (await list(ids.tenant)).rows.find((row) => row.user_id === newId);
    assert.equal(listed?.can_manage_account, true);
    assert.equal((await list(ids.tenant)).rows.find((row) => row.user_id === ids.admin)?.can_manage_account, false);
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nuevo Agente"), /permission denied/);
    await db.exec("reset role; set role service_role");
    await assert.rejects(account(ids.secondAdmin, newId, "No permitido", "Nuevo Agente"), /administrador activo/);
    await assert.rejects(account(ids.admin, ids.admin, "No permitido", ""), /administrador activo/);
    await assert.rejects(account(ids.admin, newId, "No permitido", "Obsoleto"), /nombre cambio/);
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nuevo Agente", "plaintext"), /credencial/);
    await account(ids.admin, newId, " Nombre Editado ", "Nuevo Agente");
    await db.exec("reset role");
    assert.equal((await sql("select full_name from user_profiles where user_id=$1", [newId])).rows[0].full_name, "Nombre Editado");
    assert.equal((await sql("select encrypted_password from auth.users where id=$1", [newId])).rows[0].encrypted_password, "changed-hash");
    const temporaryHash = await hash("Temporary-New123!", 12);
    await sql("insert into auth.sessions values($1,$1)", [newId]);
    await sql("insert into auth.refresh_tokens values($1)", [newId]);
    await db.exec("set role service_role");
    await account(ids.admin, newId, "Nombre Editado", "Nombre Editado", temporaryHash);
    await db.exec("reset role");
    const authRecord = (await sql("select encrypted_password,raw_user_meta_data->>'full_name' as name,raw_app_meta_data->>'must_set_password' as required from auth.users where id=$1", [newId])).rows[0];
    assert.equal(authRecord.name, "Nombre Editado");
    assert.equal(authRecord.required, "true");
    assert.equal(await compare("Temporary-New123!", String(authRecord.encrypted_password)), true);
    assert.equal((await sql("select * from auth.sessions where user_id=$1", [newId])).rows.length, 0);
    assert.equal((await sql("select * from auth.refresh_tokens where user_id=$1", [newId])).rows.length, 0);
    await login(newId);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, null);
    await db.exec("reset role");
    await sql("update auth.users set encrypted_password='owner-changed-again' where id=$1", [newId]);
    await login(newId);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, "operator");
    await db.exec("reset role");
    await sql("insert into platform_tenant_grants(platform_user_id,tenant_id,tenant_role) values($1,$2,'operator')", [newId, ids.other]);
    await db.exec("set role service_role");
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nombre Editado"), /Cuenta compartida/);
    await db.exec("reset role");
    await sql("delete from platform_tenant_grants where platform_user_id=$1", [newId]);
    await sql("insert into platform_memberships(user_id,role) values($1,'platform_support')", [newId]);
    await db.exec("set role service_role");
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nombre Editado"), /Cuenta compartida/);
    await db.exec("reset role");
    await sql("delete from platform_memberships where user_id=$1", [newId]);
    await sql("update auth.users set banned_until=now()+interval '1 day' where id=$1", [newId]);
    await db.exec("set role service_role");
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nombre Editado"), /Cuenta compartida/);
    await db.exec("reset role");
    await sql("update auth.users set banned_until=null where id=$1", [newId]);
    await sql("update tenant_memberships set role='tenant_admin' where user_id=$1 and tenant_id=$2", [ids.secondAdmin, ids.tenant]);
    await sql("update tenant_memberships set is_active=false where user_id=$1 and tenant_id=$2", [ids.admin, ids.tenant]);
    await db.exec("set role service_role");
    await assert.rejects(account(ids.admin, newId, "No permitido", "Nombre Editado"), /administrador activo/);
    };
    await login(ids.agent);
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

    await db.exec("reset role");
    await db.exec(await Deno.readTextFile(new URL("20261106160000_create_tenant_users.sql", migrations)));
    const newId = "10000000-0000-0000-0000-000000000007";
    await sql(`insert into auth.users(id,email,encrypted_password,raw_app_meta_data,raw_user_meta_data)
      values($1,'new@example.test','temporary-hash',$2,'{"must_set_password":true}')`,
      [newId, JSON.stringify({
        must_set_password: true, tenant_creation_actor: ids.admin, tenant_creation_id: ids.tenant,
      })]);
    const finish = (actor = ids.admin, tenant = ids.tenant, role = "operator", target = newId) =>
      sql("select finish_tenant_user_creation($1,$2,$3,' Nuevo Agente ',$4)", [actor, tenant, target, role]);
    await login(ids.admin);
    await assert.rejects(finish(), /permission denied/);
    await db.exec("reset role; grant usage on schema public to service_role; set role service_role");
    await assert.rejects(finish(ids.secondAdmin), /administrador activo/);
    await assert.rejects(finish(ids.admin, ids.other), /administrador activo/);
    await assert.rejects(finish(ids.admin, ids.tenant, "platform_owner"), /no valido/);
    await assert.rejects(finish(ids.admin, ids.tenant, "operator", ids.outsider), /cuentas nuevas/);
    await finish();
    await assert.rejects(finish(), /cuentas nuevas/);
    await db.exec("reset role");
    assert.equal((await sql("select * from tenant_memberships where user_id=$1", [newId])).rows.length, 1);
    assert.equal((await sql("select full_name from user_profiles where user_id=$1", [newId])).rows[0].full_name, "Nuevo Agente");
    await login(newId);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, null);
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 0);
    await db.exec("reset role");
    // User-editable metadata alone must not bypass the password requirement.
    await sql(`update auth.users set raw_user_meta_data='{"must_set_password":false}' where id=$1`, [newId]);
    await login(newId);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, null);
    await db.exec("reset role");
    await sql("update auth.users set encrypted_password='changed-hash' where id=$1", [newId]);
    await login(newId);
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.tenant])).rows[0].role, "operator");
    assert.equal((await sql("select current_tenant_role($1) as role", [ids.other])).rows[0].role, null);
    assert.equal((await sql("select * from whatsapp_contacts")).rows.length, 1);
    await testAccountEditing(newId);
  } finally {
    await db.close();
  }
});
