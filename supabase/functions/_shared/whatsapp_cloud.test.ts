import assert from "node:assert/strict";
import { connectWhatsAppCloud } from "../connect-whatsapp-cloud/index.ts";

Deno.test("cloud number verifies app and ownership before saving and subscribing", async () => {
  const original = globalThis.fetch;
  const values = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_ANON_KEY: "anon",
    SUPABASE_SERVICE_ROLE_KEY: "service",
  };
  const previous = new Map(Object.keys(values).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(values)) Deno.env.set(key, value);
  let validApp = true, foundPhone = true, coexistence = false, databaseRejects = false, subscriptionFails = false;
  let role = "tenant_admin";
  let saves = 0, subscriptions = 0;
  globalThis.fetch = (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.includes("/auth/v1/user")) return Promise.resolve(Response.json({ id: "user" }));
    if (url.includes("/is_current_user_disabled")) return Promise.resolve(Response.json(false));
    if (url.includes("/current_tenant_role")) return Promise.resolve(Response.json(role));
    if (url.includes("/read_platform_meta_configuration")) {
      return Promise.resolve(Response.json({ app_id: "123", app_secret: "app-secret" }));
    }
    if (url.includes("debug_token")) {
      return Promise.resolve(Response.json({ data: { is_valid: true, app_id: validApp ? "123" : "456" } }));
    }
    if (url.includes("/phone_numbers?")) {
      return Promise.resolve(Response.json({ data: foundPhone ? [{ id: "22", display_phone_number: "test", verified_name: "test", is_on_biz_app: coexistence }] : [] }));
    }
    if (url.includes("/connect_whatsapp_cloud_number")) {
      saves++;
      return Promise.resolve(databaseRejects
        ? Response.json({ code: "conflict" }, { status: 409 })
        : Response.json("account"));
    }
    if (url.includes("/subscribed_apps")) {
      subscriptions++;
      assert.equal(init?.method, "POST");
      return Promise.resolve(subscriptionFails
        ? Response.json({ error: { code: 200 } }, { status: 400 })
        : Response.json({ success: true }));
    }
    throw new Error("Unexpected request");
  };
  const request = () => new Request("https://example.test", {
    method: "POST",
    headers: { authorization: "Bearer user-session", "content-type": "application/json" },
    body: JSON.stringify({ tenant_id: "tenant", waba_id: "11", phone_number_id: "22", access_token: "private-token" }),
  });
  try {
    role = "operator";
    assert.equal((await connectWhatsAppCloud(request())).status, 403);
    assert.equal(saves, 0);
    role = "tenant_admin";
    validApp = false;
    assert.equal((await connectWhatsAppCloud(request())).status, 403);
    assert.equal(saves, 0);
    validApp = true; foundPhone = false;
    assert.equal((await connectWhatsAppCloud(request())).status, 403);
    assert.equal(saves, 0);
    foundPhone = true; coexistence = true;
    assert.equal((await connectWhatsAppCloud(request())).status, 409);
    assert.equal(saves, 0);
    coexistence = false; databaseRejects = true;
    assert.equal((await connectWhatsAppCloud(request())).status, 409);
    assert.equal(subscriptions, 0);
    databaseRejects = false; subscriptionFails = true;
    const warning = await connectWhatsAppCloud(request());
    assert.equal(warning.status, 200);
    assert.match((await warning.json()).warning, /webhook/);
    subscriptionFails = false;
    const success = await connectWhatsAppCloud(request());
    const result = await success.json();
    assert.equal(result.ok, true);
    assert.ok(!JSON.stringify(result).includes("private-token"));
    assert.equal(subscriptions, 2);
  } finally {
    globalThis.fetch = original;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
