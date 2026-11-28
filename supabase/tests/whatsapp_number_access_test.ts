import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("number permissions isolate conversations, messages and bot controls", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const otherTenant = "10000000-0000-0000-0000-000000000002";
  const admin = "20000000-0000-0000-0000-000000000001";
  const operator = "20000000-0000-0000-0000-000000000002";
  const platformAdmin = "20000000-0000-0000-0000-000000000003";
  const a = "30000000-0000-0000-0000-000000000001";
  const b = "30000000-0000-0000-0000-000000000002";
  const conversation = "40000000-0000-0000-0000-000000000001";
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('app.user', true),'')::uuid
      $$;
      create table tenants(id uuid primary key);
      create table tenant_memberships(tenant_id uuid,user_id uuid,is_active boolean,role text);
      create table platform_tenant_grants(tenant_id uuid,platform_user_id uuid,tenant_role text);
      create function current_tenant_role(p_tenant uuid) returns text language sql stable security definer as $$
        select role from tenant_memberships where tenant_id=p_tenant and user_id=auth.uid() and is_active
        union all
        select tenant_role from platform_tenant_grants where tenant_id=p_tenant and platform_user_id=auth.uid()
        limit 1
      $$;
      create function has_membership(p_tenant uuid) returns boolean language sql stable security definer as $$
        select exists(select 1 from tenant_memberships where tenant_id=p_tenant and user_id=auth.uid())
      $$;
      create table whatsapp_accounts(
        id uuid primary key default gen_random_uuid(),tenant_id uuid,
        phone_number_id text unique, business_account_id text, access_token text,
        display_phone_number text, name text, status text, onboarding_mode text,
        updated_at timestamptz default now(),
        constraint whatsapp_accounts_tenant_id_business_account_id_key unique(tenant_id,business_account_id)
      );
      create table whatsapp_contacts(id uuid primary key,tenant_id uuid,whatsapp_account_id uuid);
      create table whatsapp_conversations(id uuid primary key,tenant_id uuid,whatsapp_account_id uuid,contact_id uuid);
      create table whatsapp_messages(id uuid primary key,tenant_id uuid,whatsapp_account_id uuid);
      create table whatsapp_bot_sessions(tenant_id uuid,account_id uuid);
      create table whatsapp_bot_jobs(tenant_id uuid,account_id uuid);
      create table notifications(tenant_id uuid,recipient_user_id uuid,type text,data jsonb,body text);
      create table control_log(conversation_id uuid);
      create function control_whatsapp_bot(uuid,uuid,text,text default '') returns void
        language sql security definer as $$ insert into control_log values($2) $$;
      grant execute on function control_whatsapp_bot(uuid,uuid,text,text) to authenticated;
      insert into auth.users values('${admin}'),('${operator}'),('${platformAdmin}');
      insert into tenants values('${tenant}'),('${otherTenant}');
      insert into tenant_memberships values('${tenant}','${admin}',true,'tenant_admin'),
        ('${tenant}','${operator}',true,'operator');
      insert into platform_tenant_grants values('${tenant}','${platformAdmin}','tenant_admin');
      insert into whatsapp_accounts(id,tenant_id,phone_number_id,business_account_id,onboarding_mode)
        values('${a}','${tenant}','11','21','coexistence'),('${b}','${tenant}','12','22','cloud_api');
      insert into whatsapp_contacts values('${conversation}','${tenant}','${a}');
      insert into whatsapp_conversations values('${conversation}','${tenant}','${a}','${conversation}');
      insert into whatsapp_messages values('${conversation}','${tenant}','${a}');
      insert into notifications values
        ('${tenant}','${operator}','whatsapp_inbound',jsonb_build_object('conversation_id','${conversation}'),'message'),
        ('${tenant}','${operator}','unanswered_chat',jsonb_build_object('conversation_id','${conversation}'),'pending'),
        ('${tenant}','${operator}','other','{}','other');
      alter table whatsapp_accounts enable row level security;
      alter table whatsapp_contacts enable row level security;
      alter table whatsapp_conversations enable row level security;
      alter table whatsapp_messages enable row level security;
      alter table whatsapp_bot_sessions enable row level security;
      alter table whatsapp_bot_jobs enable row level security;
      alter table notifications enable row level security;
      grant select on whatsapp_accounts,whatsapp_contacts,whatsapp_conversations,whatsapp_messages,
        whatsapp_bot_sessions,whatsapp_bot_jobs to authenticated;
      grant select,update on notifications to authenticated;
      create policy allow_read on notifications for select to authenticated using(recipient_user_id=auth.uid());
      create policy allow_update on notifications for update to authenticated using(recipient_user_id=auth.uid());
      create policy allow_read on whatsapp_accounts for select to authenticated using(has_membership(tenant_id));
      create policy allow_read on whatsapp_contacts for select to authenticated using(has_membership(tenant_id));
      create policy allow_read on whatsapp_conversations for select to authenticated using(has_membership(tenant_id));
      create policy allow_read on whatsapp_messages for select to authenticated using(has_membership(tenant_id));
      create policy allow_read on whatsapp_bot_sessions for select to authenticated using(true);
      create policy allow_read on whatsapp_bot_jobs for select to authenticated using(true);
    `);
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261127184000_whatsapp_number_access.sql", import.meta.url)));
    await db.exec("set role service_role");
    const cloud = await db.query<{id:string}>(
      "select connect_whatsapp_cloud_number($1,'13','21','private-token','test','test') as id", [tenant]);
    assert.ok(cloud.rows[0].id);
    await assert.rejects(db.query(
      "select connect_whatsapp_cloud_number($1,'14','21','private-token','test','test')", [otherTenant]), /otra empresa/);
    await assert.rejects(db.query(
      "select connect_whatsapp_cloud_number($1,'11','21','private-token','test','test')", [tenant]), /otra conexion/);
    await db.exec("reset role");
    await db.query("select set_config('app.user',$1,false)", [operator]);
    await db.exec("set role authenticated");
    assert.equal((await db.query("select id from whatsapp_accounts")).rows.length, 0);
    assert.equal((await db.query("select id from whatsapp_messages")).rows.length, 0);
    assert.deepEqual((await db.query<{type:string}>("select type from notifications")).rows.map((r) => r.type), ["other"]);
    assert.equal((await db.query("update notifications set body='changed' where type='whatsapp_inbound' returning type")).rows.length, 0);
    await assert.rejects(db.query("select control_whatsapp_bot($1,$2,'pause','')", [tenant,conversation]), /No tienes acceso/);
    await assert.rejects(db.query("select set_whatsapp_number_access($1,$2,$3,true)", [tenant,a,operator]), /Solo un administrador/);
    await db.query("select set_config('app.user',$1,false)", [admin]);
    await assert.rejects(db.query("select set_whatsapp_number_access($1,$2,$3,true)", [otherTenant,a,operator]), /Solo un administrador/);
    await db.query("select set_whatsapp_number_access($1,$2,$3,true)", [tenant,a,operator]);
    await db.query("select set_config('app.user',$1,false)", [operator]);
    assert.deepEqual((await db.query<{id:string}>("select id from whatsapp_accounts")).rows.map((r) => r.id), [a]);
    assert.equal((await db.query("select id from whatsapp_conversations")).rows.length, 1);
    assert.equal((await db.query("select id from whatsapp_messages")).rows.length, 1);
    assert.equal((await db.query("select type from notifications")).rows.length, 3);
    await db.query("select control_whatsapp_bot($1,$2,'pause','')", [tenant,conversation]);
    await db.query("select set_config('app.user',$1,false)", [admin]);
    await db.query("select set_whatsapp_number_access($1,$2,$3,false)", [tenant,a,operator]);
    await db.query("select set_config('app.user',$1,false)", [operator]);
    assert.equal((await db.query("select id from whatsapp_conversations")).rows.length, 0);
    assert.deepEqual((await db.query<{type:string}>("select type from notifications")).rows.map((r) => r.type), ["other"]);
    await assert.rejects(db.query("select control_whatsapp_bot($1,$2,'pause','')", [tenant,conversation]), /No tienes acceso/);
    await db.query("select set_config('app.user',$1,false)", [platformAdmin]);
    assert.equal((await db.query("select id from whatsapp_accounts")).rows.length, 3);
    assert.equal((await db.query("select id from whatsapp_conversations")).rows.length, 1);
    assert.equal((await db.query("select id from whatsapp_messages")).rows.length, 1);
  } finally { await db.close(); }
});
