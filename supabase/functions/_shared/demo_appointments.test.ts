import assert from "node:assert/strict";
import { demoAppointments } from "../demo-appointments/index.ts";

Deno.test("demo endpoint rejects unauthenticated access and malformed input", async () => {
  const oldUrl = Deno.env.get("SUPABASE_URL"), oldKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.set("SUPABASE_URL", "https://example.supabase.co");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-key");
  try {
    const request = (path: string, data: string, headers: HeadersInit = {}) =>
      new Request(`https://example.test/functions/v1/demo-appointments/${path}`, {
        method: "POST", headers: {"content-type": "application/json", ...headers}, body: data,
      });
    assert.equal((await demoAppointments(request("instalar", '{"tenant_id":"abc"}'))).status, 401);
    assert.equal((await demoAppointments(request("buscar", '{"cedula":"DEMO-001"}'))).status, 401);
    assert.equal((await demoAppointments(request("buscar", "not-json"))).status, 400);
    assert.equal((await demoAppointments(request("buscar", "x".repeat(4097)))).status, 413);
    assert.equal((await demoAppointments(request("other", "{}"))).status, 404);
  } finally {
    if (oldUrl === undefined) Deno.env.delete("SUPABASE_URL"); else Deno.env.set("SUPABASE_URL", oldUrl);
    if (oldKey === undefined) Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY"); else Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", oldKey);
  }
});
