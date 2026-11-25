import assert from "node:assert/strict";
import { botWorker } from "../whatsapp-bot-worker/index.ts";

Deno.test("worker authenticates, sends/persists once, completes skipped jobs and pauses uncertain sends", async () => {
  const original = globalThis.fetch;
  const env = ["WHATSAPP_BOT_WORKER_SECRET", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"];
  const before = env.map((k) => Deno.env.get(k));
  Deno.env.set(env[0], "worker-test-secret");
  Deno.env.set(env[1], "https://example.supabase.co");
  Deno.env.set(env[2], "service-test-key");
  let claims = 0, sends = 0, persisted = 0;
  let enabled = true, uncertain = false, paused = false;
  let finished: string | null = null;
  let effectStatus = "";
  let session: Record<string, unknown> | null = null;
  const savedStatuses: string[] = [];
  const graph = {
    schema: 1, nodes: [{ id: "s", kind: "start", config: {} },
      { id: "t", kind: "text", config: { text: "Hola {{contact_name}}" } }, { id: "e", kind: "end", config: {} }],
    edges: [{ from: "s", port: "Siguiente", to: "t" }, { from: "t", port: "Siguiente", to: "e" }],
  };
  const reply = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init), url = new URL(request.url);
    if (url.hostname === "graph.facebook.com") {
      sends++;
      const body = await request.json();
      assert.equal(body.to, "573001234567");
      assert.equal(body.text.body, "Hola Empresa");
      if (uncertain) throw new TypeError("network disconnected after send");
      return reply({ messages: [{ id: "wamid.test" }] });
    }
    const table = url.pathname.split("/").at(-1);
    if (url.pathname.includes("/rpc/")) {
      const body = await request.json();
      switch (table) {
        case "claim_whatsapp_bot_job":
          return reply(claims++ === 0 ? { id: "job", tenant_id: "tenant", account_id: "account",
            conversation_id: "conversation", message_id: "message", lease: "lease" } : null);
        case "save_whatsapp_bot_session":
          session = body.p_state;
          savedStatuses.push(body.p_state.status);
          return reply(null);
        case "reserve_whatsapp_bot_effect":
          if (paused) return reply({ message: "Bot pausado", code: "P0001" }, 400);
          effectStatus = "started";
          return reply(null);
        case "finish_whatsapp_bot_job":
          finished = body.p_error ?? "done";
          return reply(null);
        default: throw new Error(`Unexpected RPC ${table}`);
      }
    }
    if (request.method === "GET") {
      switch (table) {
        case "whatsapp_bot_bindings": return reply([{ enabled, flow_id: "flow", version: 1 }]);
        case "whatsapp_bot_sessions": return reply(session ? [session] : []);
        case "whatsapp_accounts": return reply({ status: "active", onboarding_mode: "coexistence", phone_number_id: "phone", access_token: "account-test-token" });
        case "whatsapp_conversations": return reply({ contact_id: "contact" });
        case "whatsapp_contacts": return reply({ phone_number: "573001234567", display_name: "Empresa" });
        case "automation_flow_versions": return reply({ graph });
        case "whatsapp_messages":
          return reply(url.searchParams.has("id")
            ? { body: "Hola", message_type: "text", provider_timestamp: new Date().toISOString() }
            : [{ provider_timestamp: new Date().toISOString() }]);
      }
    } else {
      if (table === "whatsapp_messages") { persisted++; return reply(null, 201); }
      if (table === "whatsapp_conversations") return reply(null);
      if (table === "whatsapp_bot_effects") { effectStatus = (await request.json()).status; return reply(null); }
    }
    throw new Error(`Unexpected request: ${request.method} ${url.pathname}`);
  };
  const run = () => botWorker(new Request("https://worker.test", { method: "POST", headers: { "x-bot-secret": "worker-test-secret" } }));
  const reset = () => { claims = 0; session = null; finished = null; effectStatus = ""; };
  try {
    assert.equal((await botWorker(new Request("https://worker.test", { method: "POST" }))).status, 401);
    assert.equal(sends, 0);
    assert.equal((await run()).status, 200);
    assert.equal(sends, 1); assert.equal(persisted, 1); assert.equal(finished, "done");
    assert.equal(effectStatus, "confirmed");
    assert.equal(savedStatuses.at(-1), "completed");
    reset(); enabled = false;
    await run();
    assert.equal(finished, "done"); assert.equal(sends, 1);
    reset(); enabled = true; paused = true;
    await run();
    assert.match(String(finished), /Bot pausado/); assert.equal(sends, 1);
    reset(); paused = false; uncertain = true;
    await run();
    assert.equal(sends, 2); assert.equal(persisted, 1);
    assert.equal(effectStatus, "unknown");
    assert.match(String(finished), /network disconnected/);
    await run();
    assert.equal(sends, 2);
  } finally {
    globalThis.fetch = original;
    env.forEach((key, i) => before[i] === undefined ? Deno.env.delete(key) : Deno.env.set(key, before[i]!));
  }
});
