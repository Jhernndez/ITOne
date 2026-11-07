import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("flow drafts and immutable simulation versions enforce tenant roles and concurrency", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  const admin = "10000000-0000-0000-0000-000000000003";
  const supervisor = "10000000-0000-0000-0000-000000000004";
  const agent = "10000000-0000-0000-0000-000000000005";
  const sql = (query: string, values: unknown[] = []) => db.query<Record<string, unknown>>(query, values);
  const login = async (id: string) => {
    await db.exec("reset role");
    await sql("select set_config('request.jwt.claim.sub',$1,false)",[id]);
    await db.exec("set role authenticated");
  };
  const graph: {
    schema:number;
    nodes:{id:string;kind:string;x:number;y:number;config:Record<string,string>}[];
    edges:{from:string;port:string;to:string}[];
  } = {
    schema: 1,
    nodes: [
      {id:"s",kind:"start",x:60,y:80,config:{}},
      {id:"q",kind:"options",x:400,y:80,config:{text:"Tipo",variable:"tipo",options:"EPS|Particular"}},
      {id:"e",kind:"end",x:800,y:80,config:{}},
    ],
    edges:[{from:"s",port:"Siguiente",to:"q"},{from:"q",port:"EPS",to:"e"},{from:"q",port:"Particular",to:"e"}],
  };
  const save = async (g = graph, id: string | null = null, revision: number | null = null, t = tenant) => {
    const result = await sql("select save_automation_flow($1,$2,'Flujo prueba',$3,$4) as flow",[t,id,JSON.stringify(g),revision]);
    return result.rows[0].flow as {id:string;revision:number;published_version:number|null};
  };
  const publish = (id: string, revision: number, t=tenant) =>
    sql("select publish_automation_flow($1,$2,$3) as flow",[t,id,revision]);
  try {
    await db.exec(`
      create role anon; create role authenticated;
      create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql as
        'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
      create table public.tenants(id uuid primary key);
      create table public.tenant_memberships(tenant_id uuid,user_id uuid,role text,is_active boolean default true);
      create function public.current_tenant_role(t uuid) returns text language sql stable security definer as
        'select role from public.tenant_memberships where tenant_id=t and user_id=auth.uid() and is_active';
      grant usage on schema public,auth to authenticated;
      alter default privileges in schema public grant all on tables to anon,authenticated;
      insert into auth.users values('${admin}'),('${supervisor}'),('${agent}');
      insert into tenants values('${tenant}'),('${other}');
      insert into tenant_memberships(tenant_id,user_id,role) values
        ('${tenant}','${admin}','tenant_admin'),('${tenant}','${supervisor}','supervisor'),
        ('${tenant}','${agent}','operator'),('${other}','${agent}','tenant_admin');
    `);
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261106183000_automation_flows.sql",import.meta.url)));
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261106193000_expand_automation_canvas.sql",import.meta.url)));
    await login(admin);
    await assert.rejects(sql("select save_automation_flow($1,null,'Bad schema',$2,null)",[
      tenant,JSON.stringify({...graph,schema:"1"}),
    ]),/Formato/);
    let flow = await save();
    assert.equal(flow.revision,1);
    await assert.rejects(save(graph,null,null,other),/administrador activo/);
    await assert.rejects(publish(flow.id,9),/borrador cambio/);
    await publish(flow.id,1);
    assert.equal((await sql("select * from automation_flow_versions")).rows.length,1);
    await assert.rejects(save(graph,flow.id,1),/borrador cambio/);
    const edited = structuredClone(graph);
    edited.nodes[1].config.text = "Tipo nuevo";
    flow = await save(edited,flow.id,2);
    const v1 = (await sql("select graph from automation_flow_versions where version=1")).rows[0].graph;
    assert.deepEqual(v1,graph);
    await assert.rejects(sql("update automation_flow_versions set name='hack'"),/permission denied/);
    await assert.rejects(sql("update automation_flows set name='hack'"),/permission denied/);
    await publish(flow.id,flow.revision);
    assert.equal((await sql("select * from automation_flow_versions")).rows.length,2);
    assert.deepEqual((await sql("select distinct mode from automation_flow_versions")).rows,[{mode:"simulation"}]);
    const chain = {
      schema:1,
      nodes:Array.from({length:60},(_,i)=>({
        id:`n${i}`,kind:i===0?"start":i===59?"end":"text",x:60,y:80,config:{text:"Mensaje ficticio"},
      })),
      edges:Array.from({length:59},(_,i)=>({from:`n${i}`,port:"Siguiente",to:`n${i+1}`})),
    };
    const chainFlow = await save(chain);
    await publish(chainFlow.id,1);
    chain.nodes.push({id:"excess",kind:"end",x:80,y:80,config:{text:""}});
    await assert.rejects(save(chain),/limites/);

    await login(supervisor);
    assert.equal((await sql("select * from automation_flows")).rows.length,2);
    assert.equal((await sql("select * from automation_flow_versions")).rows.length,3);
    await assert.rejects(save(),/administrador activo/);
    await assert.rejects(publish(flow.id,flow.revision),/administrador activo/);
    await login(agent);
    assert.equal((await sql("select * from automation_flows")).rows.length,0);
    assert.equal((await sql("select * from automation_flow_versions")).rows.length,0);
    await assert.rejects(publish(flow.id,flow.revision,other),/borrador cambio/);
    await login(admin);
    const missing = structuredClone(graph); missing.edges.pop();
    const invalid = await save(missing);
    await assert.rejects(publish(invalid.id,1),/salidas sin conectar/);
    const cycle = structuredClone(graph); cycle.edges[1].to = "q";
    cycle.nodes[0].x = -8000; cycle.nodes[1].y = 19000;
    const cycled = await save(cycle);
    await publish(cycled.id,1);
    const snapshot = (await sql("select graph from automation_flow_versions where flow_id=$1",[cycled.id])).rows[0].graph;
    assert.deepEqual(snapshot,cycle);
    cycle.nodes[0].x = 1000000001;
    await assert.rejects(save(cycle),/posicion/);
    const orphan = structuredClone(graph);
    orphan.nodes.push({id:"orphan",kind:"end",x:900,y:900,config:{}});
    const orphaned = await save(orphan);
    await assert.rejects(publish(orphaned.id,1),/sin conexion/);
    const badOptions = structuredClone(graph); badOptions.nodes[1].config.options="EPS|EPS";
    const bad = await save(badOptions);
    await assert.rejects(publish(bad.id,1),/opciones unicas/);
    const wrongTarget = structuredClone(graph); wrongTarget.edges[0].to="missing";
    await assert.rejects(save(wrongTarget),/inexistente/);
    await db.exec("reset role");
    await sql("update tenant_memberships set is_active=false where user_id=$1",[admin]);
    await login(admin);
    assert.equal((await sql("select * from automation_flows")).rows.length,0);
    await assert.rejects(save(),/administrador activo/);
    await assert.rejects(publish(flow.id,4),/administrador activo/);
    await db.exec("reset role; set role anon");
    await assert.rejects(save(),/permission denied/);
  } finally { await db.close(); }
});
