import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("production bots isolate tenants, opt in, deduplicate, serialize and preserve human takeover", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  const owner = "10000000-0000-0000-0000-000000000003";
  const operator = "10000000-0000-0000-0000-000000000004";
  const account = "10000000-0000-0000-0000-000000000005";
  const conversation = "10000000-0000-0000-0000-000000000006";
  const flow = "10000000-0000-0000-0000-000000000007";
  const query = (s: string, values: unknown[] = []) => db.query<Record<string, unknown>>(s, values);
  const login = async (id: string) => {
    await db.exec("reset role");
    await query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
    await db.exec("set role authenticated");
  };
  const graph = {
    schema: 1, nodes: [{ id: "s", kind: "start", x: 0, y: 0, config: {} },
      { id: "e", kind: "end", x: 100, y: 0, config: {} }],
    edges: [{ from: "s", port: "Siguiente", to: "e" }],
  };
  const inbound = async (source = "cloud_api", direction = "inbound", edited: string | null = null) =>
    (await query(`insert into whatsapp_messages(tenant_id,conversation_id,whatsapp_account_id,source,direction,original_message_id)
      values($1,$2,$3,$4,$5,$6) returning id`, [tenant, conversation, account, source, direction, edited])).rows[0].id;
  const claim = async () => (await query("select claim_whatsapp_bot_job() as job")).rows[0].job as
    { id: string; lease: string } | null;
  const save = (job: { id: string; lease: string }, status = "running", nodeId = "s", version = 1) => query(
    "select save_whatsapp_bot_session($1,$2,$3)", [job.id, job.lease, JSON.stringify({
      flow_id: flow, version, node_id: nodeId, status, variables: {}, steps: 1,
    })]);
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role bypassrls;
      create schema auth; create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql as
        'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
      create table tenants(id uuid primary key);
      create table tenant_memberships(tenant_id uuid,user_id uuid,role text,is_active boolean default true);
      create table platform_tenant_grants(tenant_id uuid, platform_user_id uuid);
      create function current_tenant_role(t uuid) returns text language sql stable security definer as
        'select role from tenant_memberships where tenant_id=t and user_id=auth.uid() and is_active';
      grant usage on schema public,auth to authenticated,service_role;
      create table whatsapp_accounts(id uuid primary key,tenant_id uuid,status text,onboarding_mode text,access_token text);
      create table whatsapp_conversations(id uuid primary key,tenant_id uuid,whatsapp_account_id uuid,contact_id uuid);
      create table whatsapp_contacts(id uuid primary key,tenant_id uuid,whatsapp_account_id uuid);
      create table whatsapp_messages(id uuid primary key default gen_random_uuid(),tenant_id uuid,
        conversation_id uuid,whatsapp_account_id uuid,source text,direction text,original_message_id text);
      create table notifications(tenant_id uuid,type text,data jsonb);
      alter table notifications enable row level security;
      create table tenant_api_resources(id uuid primary key,tenant_id uuid,http_method text,
        integration_id uuid,path text,enabled boolean default true,enabled_for_automation boolean default false,allow_automation_writes boolean default false);
      create table tenant_api_integrations(id uuid primary key,tenant_id uuid,base_url text,auth_type text,auth_config jsonb,enabled boolean);
      insert into auth.users values('${owner}'),('${operator}');
      insert into tenants values('${tenant}'),('${other}');
      insert into tenant_memberships values('${tenant}','${owner}','tenant_admin',true),
        ('${tenant}','${operator}','operator',true);
      insert into whatsapp_accounts values('${account}','${tenant}','active','coexistence','fake-token');
      insert into whatsapp_conversations(id,tenant_id,whatsapp_account_id) values('${conversation}','${tenant}','${account}');
    `);
    for (const migration of ["20261106183000_automation_flows.sql", "20261106193000_expand_automation_canvas.sql",
      "20261125170000_whatsapp_automation_runtime.sql", "20261127180000_bot_worker_read_permissions.sql",
      "20261127184000_whatsapp_number_access.sql"]) {
      await db.exec(await Deno.readTextFile(new URL(`../migrations/${migration}`, import.meta.url)));
    }
    await query("insert into automation_flows(id,tenant_id,name,draft) values($1,$2,'Real',$3)", [flow, tenant, JSON.stringify(graph)]);
    await query("insert into automation_flow_versions(tenant_id,flow_id,version,name,graph) values($1,$2,1,'Real',$3)",
      [tenant, flow, JSON.stringify(graph)]);
    await db.exec("set role service_role");
    const workerGraph = await query("select graph from automation_flow_versions where tenant_id=$1 and flow_id=$2 and version=1", [tenant,flow]);
    assert.deepEqual(workerGraph.rows[0].graph, graph);
    await query("select integration_id,path,http_method,enabled,enabled_for_automation,allow_automation_writes from tenant_api_resources where tenant_id=$1 and id=$2", [tenant,flow]);
    await query("select base_url,auth_type,auth_config,enabled from tenant_api_integrations where tenant_id=$1 and id=$2", [tenant,flow]);
    await assert.rejects(query("update automation_flow_versions set graph='{}'"), /permission denied/);
    await db.exec("reset role");
    await inbound();
    assert.equal((await query("select * from whatsapp_bot_jobs")).rows.length, 0);
    await login(operator);
    await assert.rejects(query("select configure_whatsapp_bot($1,$2,$3,1,true)", [tenant, account, flow]), /administrador/);
    await assert.rejects(query("select claim_whatsapp_bot_job()"), /permission denied/);
    await login(owner);
    await query("select set_whatsapp_number_access($1,$2,$3,true)", [tenant, account, operator]);
    await assert.rejects(query("select configure_whatsapp_bot($1,$2,$3,1,true)", [other, account, flow]), /administrador/);
    await query("select configure_whatsapp_bot($1,$2,$3,1,true)", [tenant, account, flow]);
    await db.exec("reset role");
    await query("update whatsapp_accounts set onboarding_mode='cloud_api' where id=$1", [account]);
    await login(owner);
    await query("select configure_whatsapp_bot($1,$2,$3,1,true)", [tenant, account, flow]);
    await db.exec("reset role");
    await inbound("history");
    await inbound("cloud_api", "inbound", "edited-original");
    assert.equal((await query("select * from whatsapp_bot_jobs")).rows.length, 0);
    const message = await inbound();
    await query(`insert into whatsapp_bot_jobs(tenant_id,account_id,conversation_id,message_id) values($1,$2,$3,$4)
      on conflict(message_id) do nothing`, [tenant, account, conversation, message]);
    await inbound();
    const job = await claim();
    assert.ok(job);
    assert.equal(await claim(), null);
    await save(job);
    await query("select reserve_whatsapp_bot_effect($1,$2,1,'message')", [job.id, job.lease]);
    await assert.rejects(query("select reserve_whatsapp_bot_effect($1,$2,1,'message')", [job.id, job.lease]), /duplicate key/);
    await login(operator);
    await query("select control_whatsapp_bot($1,$2,'pause')", [tenant, conversation]);
    await db.exec("reset role");
    await assert.rejects(save(job), /pausado/);
    await assert.rejects(query("select reserve_whatsapp_bot_effect($1,$2,2,'message')", [job.id, job.lease]), /pausado/);
    assert.equal((await query("select status from whatsapp_bot_sessions")).rows[0].status, "human");
    await login(operator);
    await query("select control_whatsapp_bot($1,$2,'resume')", [tenant, conversation]);
    await db.exec("reset role");
    await assert.rejects(save(job), /no disponible/);
    assert.equal((await query("select * from whatsapp_bot_sessions")).rows.length, 0);
    const reviewGraph = structuredClone(graph);
    reviewGraph.nodes.push({ id: "review", kind: "review", x: 50, y: 0, config: {} });
    reviewGraph.edges[0].to = "review";
    reviewGraph.edges.push({ from: "review", port: "Aprobada", to: "e" }, { from: "review", port: "Denegada", to: "e" });
    await query("insert into automation_flow_versions(tenant_id,flow_id,version,name,graph) values($1,$2,2,'Revision',$3)",
      [tenant, flow, JSON.stringify(reviewGraph)]);
    await login(owner);
    await query("select configure_whatsapp_bot($1,$2,$3,2,true)", [tenant, account, flow]);
    await db.exec("reset role");
    await inbound();
    const reviewJob = await claim();
    assert.ok(reviewJob);
    await save(reviewJob, "human", "review", 2);
    await query("select finish_whatsapp_bot_job($1,$2)", [reviewJob.id, reviewJob.lease]);
    assert.equal((await query("select review_pending from whatsapp_bot_sessions")).rows[0].review_pending, true);
    await login(operator);
    await assert.rejects(query("select control_whatsapp_bot($1,$2,'deny','')", [tenant, conversation]), /motivo/);
    await query("select control_whatsapp_bot($1,$2,'deny','No autorizado')", [tenant, conversation]);
    await db.exec("reset role");
    const reviewed = (await query("select node_id,status,variables,review_pending from whatsapp_bot_sessions")).rows[0];
    assert.equal(reviewed.node_id, "e");
    assert.equal(reviewed.status, "running");
    assert.equal(reviewed.review_pending, false);
    assert.deepEqual(reviewed.variables, { motivo_denegacion: "No autorizado" });
    const wake = await claim();
    assert.ok(wake);
    await query("update whatsapp_bot_jobs set started_at=now()-interval '6 minutes' where id=$1", [wake.id]);
    assert.equal(await claim(), null);
    assert.equal((await query("select status from whatsapp_bot_sessions")).rows[0].status, "error");
    assert.equal((await query("select status from whatsapp_bot_jobs where id=$1", [wake.id])).rows[0].status, "failed");
    await inbound("business_app", "outbound");
    assert.equal((await query("select status from whatsapp_bot_sessions")).rows[0].status, "human");
    await login(owner);
    await query("select configure_whatsapp_bot($1,$2,null,null,false)", [tenant, account]);
    await db.exec("reset role");
    const count = (await query("select * from whatsapp_bot_jobs")).rows.length;
    await inbound();
    assert.equal((await query("select * from whatsapp_bot_jobs")).rows.length, count);
    await login(operator);
    await assert.rejects(query("select control_whatsapp_bot($1,$2,'approve')", [tenant, conversation]), /revision/);
    await db.exec("reset role");
    await query("update tenant_memberships set is_active=false where user_id=$1", [owner]);
    await login(owner);
    assert.equal((await query("select * from whatsapp_bot_bindings")).rows.length, 0);
    await assert.rejects(query("select configure_whatsapp_bot($1,$2,$3,1,true)", [tenant, account, flow]), /administrador/);
  } finally { await db.close(); }
});
