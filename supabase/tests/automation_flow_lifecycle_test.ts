import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("flow lifecycle protects tenant data and restores snapshots without activating bots", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  const admin = "10000000-0000-0000-0000-000000000003";
  const supervisor = "10000000-0000-0000-0000-000000000004";
  const sql = (query: string, values: unknown[] = []) => db.query<Record<string, unknown>>(query, values);
  const login = async (id: string) => {
    await db.exec("reset role");
    await sql("select set_config('request.jwt.claim.sub',$1,false)", [id]);
    await db.exec("set role authenticated");
  };
  const graph = {
    schema: 1,
    nodes: [
      {id: "s", kind: "start", x: -8000, y: 19000, config: {}},
      {id: "e", kind: "end", x: 100, y: 80, config: {}},
    ],
    edges: [{from: "s", port: "Siguiente", to: "e"}],
  };
  try {
    await db.exec(`
      create role anon; create role authenticated;
      create schema auth; create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql as
        'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
      create table public.tenants(id uuid primary key);
      create table public.tenant_memberships(tenant_id uuid,user_id uuid,role text,is_active boolean default true);
      create function public.current_tenant_role(t uuid) returns text language sql stable security definer as
        'select role from public.tenant_memberships where tenant_id=t and user_id=auth.uid() and is_active';
      grant usage on schema public,auth to authenticated;
      insert into auth.users values('${admin}'),('${supervisor}');
      insert into tenants values('${tenant}'),('${other}');
      insert into tenant_memberships values
        ('${tenant}','${admin}','tenant_admin',true),('${tenant}','${supervisor}','supervisor',true);
    `);
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261106183000_automation_flows.sql", import.meta.url)));
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261106193000_expand_automation_canvas.sql", import.meta.url)));
    await db.exec(`
      alter table automation_flow_versions drop constraint automation_flow_versions_mode_check;
      alter table automation_flow_versions add constraint automation_flow_versions_mode_check check(mode in ('simulation','published'));
      create table whatsapp_bot_bindings(tenant_id uuid,flow_id uuid,version integer,
        foreign key(flow_id,version) references automation_flow_versions(flow_id,version));
      create table whatsapp_bot_sessions(tenant_id uuid,flow_id uuid,version integer,
        foreign key(flow_id,version) references automation_flow_versions(flow_id,version));
    `);
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261127170000_automation_flow_lifecycle.sql", import.meta.url)));
    await login(admin);
    const saved = await sql("select save_automation_flow($1,null,'Prueba',$2,null) as flow", [tenant, JSON.stringify(graph)]);
    const flow = saved.rows[0].flow as {id: string; revision: number};
    await sql("select publish_automation_flow($1,$2,1)", [tenant,flow.id]);
    await sql("select publish_automation_flow($1,$2,2)", [tenant,flow.id]);
    const backup = (await sql("select export_automation_flow($1,$2) as backup", [tenant,flow.id])).rows[0].backup as Record<string, unknown>;
    assert.equal((backup.versions as unknown[]).length, 2);
    await assert.rejects(sql("select restore_automation_flow($1,$2)", [other, JSON.stringify(backup)]), /administrador/);
    await assert.rejects(sql("select restore_automation_flow($1,$2)", [tenant, JSON.stringify({...backup, tenant_id: other})]), /otra empresa/);
    await assert.rejects(sql("select restore_automation_flow($1,$2)", [tenant, JSON.stringify({...backup, versions: [ (backup.versions as unknown[])[0], (backup.versions as unknown[])[0] ]})]), /duplicadas/);
    const restored = (await sql("select restore_automation_flow($1,$2) as flow", [tenant,JSON.stringify(backup)])).rows[0].flow as {id: string};
    assert.notEqual(restored.id, flow.id);
    const restoredBackup = (await sql("select export_automation_flow($1,$2) as backup", [tenant,restored.id])).rows[0].backup;
    assert.deepEqual(restoredBackup, backup);
    await assert.rejects(sql("select delete_automation_flow($1,$2,1)", [tenant,flow.id]), /cambio/);
    await db.exec("reset role");
    await sql("insert into whatsapp_bot_bindings values($1,$2,1)", [tenant,flow.id]);
    await login(admin);
    await assert.rejects(sql("select delete_automation_version($1,$2,1)", [tenant,flow.id]), /vinculada/);
    await assert.rejects(sql("select delete_automation_flow($1,$2,3)", [tenant,flow.id]), /vinculado/);
    await sql("select delete_automation_version($1,$2,2)", [tenant,flow.id]);
    await sql("select publish_automation_flow($1,$2,3)", [tenant,flow.id]);
    assert.equal((await sql("select max(version) as v from automation_flow_versions where flow_id=$1", [flow.id])).rows[0].v, 3);
    await db.exec("reset role");
    await sql("delete from whatsapp_bot_bindings");
    await sql("insert into whatsapp_bot_sessions values($1,$2,1)", [tenant,flow.id]);
    await login(admin);
    await assert.rejects(sql("select delete_automation_flow($1,$2,4)", [tenant,flow.id]), /sesiones/);
    await login(supervisor);
    await sql("select export_automation_flow($1,$2)", [tenant,flow.id]);
    await assert.rejects(sql("select delete_automation_version($1,$2,3)", [tenant,flow.id]), /administrador/);
    await assert.rejects(sql("select restore_automation_flow($1,$2)", [tenant,JSON.stringify(backup)]), /administrador/);
    await login(admin);
    await sql("select delete_automation_flow($1,$2,1)", [tenant,restored.id]);
    await assert.rejects(sql("select export_automation_flow($1,$2)", [tenant,restored.id]), /no disponible/);
  } finally { await db.close(); }
});
