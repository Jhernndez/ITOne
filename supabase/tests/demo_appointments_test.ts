import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";
import { executeFlow, type RuntimeGraph, type RuntimeState, type RuntimeEffects } from "../functions/_shared/automation_runtime.ts";

Deno.test("demo appointments isolate tenants, reserve atomically and never use real patients", async () => {
  const db = new PGlite();
  const tenant1 = "10000000-0000-0000-0000-000000000001";
  const tenant2 = "10000000-0000-0000-0000-000000000002";
  const key1 = "a".repeat(64), key2 = "b".repeat(64);
  const query = (sql: string, values: unknown[] = []) => db.query<Record<string, unknown>>(sql, values);
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create table tenants(id uuid primary key);
      create table tenant_api_integrations(id uuid primary key default gen_random_uuid(),tenant_id uuid,
        name text,base_url text,auth_type text,auth_config jsonb,unique(tenant_id,name));
      create table tenant_api_resources(id uuid primary key default gen_random_uuid(),tenant_id uuid,
        integration_id uuid,name text,path text,http_method text,enabled boolean,
        enabled_for_automation boolean,allow_automation_writes boolean);
      insert into tenants values('${tenant1}'),('${tenant2}');
    `);
    await db.exec(await Deno.readTextFile(new URL("../migrations/20261127182000_demo_appointments.sql", import.meta.url)));
    await db.exec("set role service_role");
    const install = (tenant: string, key: string) => query("select install_demo_appointments($1,$2,$3)", [tenant,"https://demo.supabase.co/functions/v1/demo-appointments",key]);
    await install(tenant1,key1);
    await install(tenant2,key2);
    await install(tenant1,key1);
    const run = async (key: string, action: string, data: object, idem: string | null = null) =>
      (await query("select run_demo_appointments($1,$2,$3,$4) as result", [key,action,JSON.stringify(data),idem])).rows[0].result as {status:number; body: Record<string, unknown>};
    await assert.rejects(run("invalid","buscar",{}),/Credencial/);
    assert.equal((await run(key1,"buscar",{cedula:"123456789"})).status,404);
    const lookup = await run(key1,"buscar",{cedula:"DEMO-001"});
    const slots = lookup.body.horarios as {id:string;nombre:string}[];
    assert.equal(slots.length,3);
    assert.equal((await run(key2,"reservar",{cedula:"DEMO-001",horario:slots[0].id},"foreign")).status,409);
    const request = {cedula:"DEMO-001",horario:slots[0].id};
    const booked = await run(key1,"reservar",request,"booking-1");
    assert.equal(booked.status,200);
    assert.deepEqual(await run(key1,"reservar",request,"booking-1"),booked);
    await assert.rejects(run(key1,"reservar",{...request, horario: slots[1].id},"booking-1"),/ya utilizada/);
    assert.equal((await run(key1,"reservar",{cedula:"DEMO-002",horario:slots[0].id},"collision")).status,409);
    assert.equal((await run(key1,"reservar",{cedula:"DEMO-001",horario:slots[0].id},"unavailable")).status,409);
    assert.equal((await run(key1,"reservar",{cedula:"DEMO-001",horario:slots[1].id},"change")).status,200);
    assert.equal((await run(key1,"reservar",{cedula:"DEMO-002",horario:slots[0].id},"new-booking")).status,200);
    const graph: RuntimeGraph = {
      schema:1,
      nodes:[
        {id:"s",kind:"start",config:{}},
        {id:"q",kind:"question",config:{text:"Identificación ficticia",variable:"cedula"}},
        {id:"lookup",kind:"api",config:{resource_id:"10000000-0000-0000-0000-000000000010",body:'{"cedula":"{{cedula}}"}',result_variable:"agenda"}},
        {id:"choice",kind:"options",config:{text:"Horarios",variable:"horario",options_mode:"dynamic",options_source:"agenda.body.horarios",option_label:"nombre",option_value:"id"}},
        {id:"book",kind:"api",config:{resource_id:"10000000-0000-0000-0000-000000000011",body:'{"cedula":"{{cedula}}","horario":"{{horario}}"}',result_variable:"cita"}},
        {id:"success",kind:"text",config:{text:"{{cita.body.mensaje}}"}},
        {id:"end",kind:"end",config:{}},
        {id:"human",kind:"handoff",config:{}},
      ],
      edges:[
        {from:"s",port:"Siguiente",to:"q"}, {from:"q",port:"Siguiente",to:"lookup"},
        {from:"lookup",port:"Éxito",to:"choice"}, {from:"lookup",port:"Error",to:"human"},
        {from:"choice",port:"Siguiente",to:"book"}, {from:"choice",port:"Sin opciones",to:"human"},
        {from:"book",port:"Éxito",to:"success"}, {from:"book",port:"Error",to:"human"},
        {from:"success",port:"Siguiente",to:"end"},
      ],
    };
    const state: RuntimeState = {flow_id:"demo",version:1,node_id:"s",variables:{},status:"running",steps:0};
    const messages: string[] = [];
    const effects: RuntimeEffects = {
      save: () => Promise.resolve(),
      send: (text) => { messages.push(text); return Promise.resolve(); },
      api: async (id, _query, payload, step) => {
        const action = id.endsWith("10") ? "buscar" : "reservar";
        const result = await run(key1,action,payload as object,`flow-${step}`);
        return {ok:result.status < 300,status_code:result.status,body:result.body as Record<string,string>};
      },
    };
    await executeFlow(graph,state,null,effects);
    await executeFlow(graph,state,"DEMO-001",effects);
    assert.equal(state.status,"waiting");
    assert.match(messages[1],/1\..*\n2\..*\n3\./);
    await executeFlow(graph,state,"2",effects);
    assert.equal(state.status,"completed");
    assert.match(messages.at(-1)!,/No es una cita real/);
    await db.exec("reset role; set role authenticated");
    await assert.rejects(run(key1,"buscar",{cedula:"DEMO-001"}),/permission denied/);
    await assert.rejects(query("select * from demo_appointment_slots"),/permission denied/);
  } finally { await db.close(); }
});
