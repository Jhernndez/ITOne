import assert from "node:assert/strict";
import { executeFlow, render, type RuntimeGraph, type RuntimeState, type RuntimeEffects } from "./automation_runtime.ts";

const state = (): RuntimeState => ({
  flow_id: "10000000-0000-0000-0000-000000000001", version: 1, node_id: "s",
  variables: {}, status: "running", steps: 0,
});
const graph = (): RuntimeGraph => ({
  schema: 1,
  nodes: [
    { id: "s", kind: "start", config: {} },
    { id: "q", kind: "question", config: { text: "Tu nombre", variable: "nombre" } },
    { id: "t", kind: "text", config: { text: "Hola {{nombre}}" } },
    { id: "e", kind: "end", config: {} },
  ],
  edges: [{ from: "s", port: "Siguiente", to: "q" }, { from: "q", port: "Siguiente", to: "t" },
    { from: "t", port: "Siguiente", to: "e" }],
});
function effects() {
  const sent: string[] = [];
  const saved: RuntimeState[] = [];
  const adapter: RuntimeEffects = {
    save: (s) => { saved.push(structuredClone(s)); return Promise.resolve(); },
    send: (text) => { sent.push(text); return Promise.resolve(); },
    api: () => Promise.resolve({ ok: true, status_code: 200, body: { id: 8 } }),
  };
  return { adapter, sent, saved };
}
Deno.test("runtime persists a question before waiting, consumes input once and finishes", async () => {
  const s = state(), e = effects(), g = graph();
  await executeFlow(g, s, "inicial", e.adapter);
  assert.equal(s.status, "waiting");
  assert.deepEqual(e.sent, ["Tu nombre"]);
  await executeFlow(g, s, "Ana", e.adapter);
  assert.equal(s.status, "completed");
  assert.equal(s.variables.nombre, "Ana");
  assert.deepEqual(e.sent, ["Tu nombre", "Hola Ana"]);
  await executeFlow(g, s, "otra", e.adapter);
  assert.equal(e.sent.length, 2);
});
Deno.test("options accept numbered input, repeat invalid choices and condition branches", async () => {
  const s = state(), e = effects(), g = graph();
  g.nodes[1] = { id: "q", kind: "options", config: { text: "Elige", variable: "tipo", options: "Ventas|Soporte" } };
  g.nodes[2] = { id: "t", kind: "condition", config: { variable: "tipo", equals: "soporte" } };
  g.edges = [{ from: "s", port: "Siguiente", to: "q" }, { from: "q", port: "Ventas", to: "e" },
    { from: "q", port: "Soporte", to: "t" }, { from: "t", port: "Sí", to: "e" },
    { from: "t", port: "No", to: "q" }];
  await executeFlow(g, s, null, e.adapter);
  await executeFlow(g, s, "equivocada", e.adapter);
  assert.equal(s.status, "waiting");
  await executeFlow(g, s, "2", e.adapter);
  assert.equal(s.status, "completed");
  assert.equal(s.variables.tipo, "Soporte");
});
Deno.test("dynamic options expose at most three items, save the selected value and route empty lists", async () => {
  const s = state(), e = effects(), g = graph();
  g.nodes[1] = { id: "q", kind: "options", config: {
    text: "Elige un horario", variable: "horario", options_mode: "dynamic", options_source: "agenda.body.horarios",
    option_label: "nombre", option_value: "id",
  } };
  g.nodes[2] = { id: "t", kind: "text", config: { text: "Elegiste {{horario}}" } };
  g.edges = [{ from: "s", port: "Siguiente", to: "q" }, { from: "q", port: "Siguiente", to: "t" },
    { from: "q", port: "Sin opciones", to: "e" }, { from: "t", port: "Siguiente", to: "e" }];
  s.variables.agenda = {body: {horarios: [
    {id: "a", nombre: "Lunes"}, {id: "b", nombre: "Martes"}, {id: "c", nombre: "Miércoles"},
    {id: "d", nombre: "Jueves"},
  ]}};
  await executeFlow(g, s, null, e.adapter);
  assert.deepEqual(e.sent, ["Elige un horario\n1. Lunes\n2. Martes\n3. Miércoles"]);
  await executeFlow(g, s, "4", e.adapter);
  assert.equal(s.status, "waiting");
  await executeFlow(g, s, "2", e.adapter);
  assert.equal(s.variables.horario, "b");
  assert.equal(e.sent.at(-1), "Elegiste b");
  const empty = state(), emptyEffects = effects();
  empty.variables.agenda = {body: {horarios: []}};
  await executeFlow(g, empty, null, emptyEffects.adapter);
  assert.equal(empty.status, "completed");
  assert.deepEqual(emptyEffects.sent, []);
});
Deno.test("API JSON mapping escapes user input and exposes nested result variables", async () => {
  const s = state(), e = effects(), g = graph();
  s.variables.id = '"quoted"';
  g.nodes[1] = { id: "q", kind: "api", config: {
    resource_id: "10000000-0000-0000-0000-000000000002",
    query: '{"id":"{{id}}"}', body: '{}', result_variable: "resultado",
  } };
  g.nodes[2].config.text = "{{resultado.body.id}}";
  g.edges[1].port = "Éxito";
  g.edges.push({ from: "q", port: "Error", to: "e" });
  e.adapter.api = (_, query) => { assert.equal(query.id, '"quoted"'); return Promise.resolve({ ok: true, status_code: 200, body: { id: 8 } }); };
  await executeFlow(g, s, null, e.adapter);
  assert.deepEqual(e.sent, ["8"]);
  assert.equal(s.status, "completed");
});
Deno.test("API definite rejection follows Error; ambiguous write stops without another side effect", async () => {
  const s = state(), e = effects(), g = graph();
  g.nodes[1] = { id: "q", kind: "api", config: { resource_id: "10000000-0000-0000-0000-000000000002" } };
  g.edges[1].port = "Éxito";
  g.edges.push({ from: "q", port: "Error", to: "e" });
  e.adapter.api = () => Promise.resolve({ ok: false, status: 422 });
  await executeFlow(g, s, null, e.adapter);
  assert.equal(s.status, "completed");
  const second = state();
  e.adapter.api = () => { throw new Error("Resultado de escritura desconocido"); };
  await assert.rejects(executeFlow(g, second, null, e.adapter), /desconocido/);
  assert.equal(e.sent.length, 0);
});
Deno.test("API response extraction supports business conditions and rejects invalid paths before execution", async () => {
  const s = state(), e = effects(), g = graph();
  g.nodes[1] = { id: "q", kind: "api", config: {
    resource_id: "10000000-0000-0000-0000-000000000002", result_variable: "estado", result_path: "body.estado",
  } };
  g.nodes[2] = { id: "t", kind: "condition", config: { variable: "estado", equals: "aprobado" } };
  g.edges = [{ from: "s", port: "Siguiente", to: "q" }, { from: "q", port: "Éxito", to: "t" },
    { from: "q", port: "Error", to: "e" }, { from: "t", port: "Sí", to: "e" },
    { from: "t", port: "No", to: "q" }];
  let calls = 0;
  e.adapter.api = () => { calls++; return Promise.resolve({ ok: true, status_code: 200, body: { estado: "APROBADO" } }); };
  await executeFlow(g, s, null, e.adapter);
  assert.equal(s.variables.estado, "APROBADO");
  assert.equal(s.status, "completed");
  assert.equal(calls, 1);
  g.nodes[1].config.result_path = "bad path";
  await assert.rejects(executeFlow(g, state(), null, e.adapter), /Ruta de resultado/);
  assert.equal(calls, 1);
});
Deno.test("review/handoff pause, unsupported nodes/missing variables/cycles fail explicitly", async () => {
  for (const kind of ["review", "handoff"]) {
    const s = state(), e = effects(), g = graph();
    g.nodes[1].kind = kind;
    await executeFlow(g, s, null, e.adapter);
    assert.equal(s.status, "human");
    assert.equal(s.node_id, "q");
    assert.equal(e.sent.length, 0);
  }
  const g = graph(), e = effects();
  g.nodes[1].kind = "unknown";
  await assert.rejects(executeFlow(g, state(), null, e.adapter), /no compatible/);
  assert.throws(() => render("{{missing}}", {}), /no disponible/);
  assert.throws(() => render("{{constructor}}", {}), /no disponible/);
  g.nodes[1].kind = "start";
  g.edges[1].to = "q";
  await assert.rejects(executeFlow(g, state(), null, e.adapter), /30 pasos/);
  const exhausted = state(); exhausted.steps = 1000;
  await assert.rejects(executeFlow(graph(), exhausted, null, e.adapter), /1000 pasos/);
});
