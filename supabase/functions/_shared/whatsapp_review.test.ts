import assert from "node:assert/strict";
import { ReviewError, reviewHandler } from "./whatsapp_review.ts";

const tenant = "10000000-0000-0000-0000-000000000001";
function setup() {
  const secrets: Record<string, string> = {
    WHATSAPP_REVIEW_TENANT_ID: tenant,
    WHATSAPP_REVIEW_PHONE_NUMBER_ID: "123456",
    WHATSAPP_REVIEW_RECIPIENT: "573000000000",
    WHATSAPP_REVIEW_ACCESS_TOKEN: "private-test-token",
  };
  let allowed = true;
  let reserveError: Error | null = null;
  let response = new Response(
    JSON.stringify({ messages: [{ id: "wamid.example" }] }),
  );
  const calls: { url: string; options?: RequestInit }[] = [];
  let reservations = 0;
  const handler = reviewHandler({
    env: (name) => secrets[name],
    authorize: async () => {
      if (!allowed) throw new ReviewError("No autorizado", 403);
    },
    reserve: async () => {
      if (reserveError) throw reserveError;
      reservations++;
    },
    fetch: (url, options) => {
      calls.push({ url: String(url), options });
      return Promise.resolve(response.clone());
    },
  });
  const request = (action = "send", extra = {}) =>
    handler(
      new Request("https://example.test", {
        method: "POST",
        body: JSON.stringify({ tenant_id: tenant, action, ...extra }),
      }),
    );
  return {
    secrets,
    calls,
    request,
    reservations: () => reservations,
    deny: () => {
      allowed = false;
    },
    throttle: () => {
      reserveError = new ReviewError("Espera un minuto", 429);
    },
    respond: (value: object, status = 200) => {
      response = new Response(JSON.stringify(value), { status });
    },
  };
}

Deno.test("review status exposes only safe configuration and does not send", async () => {
  const s = setup();
  const response = await s.request("status");
  assert.equal(response.status, 200);
  const text = await response.text();
  assert.ok(text.includes("jaspers_market_order_confirmation_v1"));
  assert.ok(!text.includes("private-test-token"));
  assert.equal(s.calls.length, 0);
  assert.equal(s.reservations(), 0);
});

Deno.test("review sends fixed template to server allowlist, ignoring client overrides", async () => {
  const s = setup();
  const response = await s.request("send", {
    recipient: "attacker",
    phone_number_id: "bad",
    token: "bad",
    template: "bad",
  });
  assert.deepEqual(await response.json(), {
    provider_message_id: "wamid.example",
    status: "accepted",
  });
  assert.equal(s.reservations(), 1);
  assert.equal(
    s.calls[0].url,
    "https://graph.facebook.com/v25.0/123456/messages",
  );
  assert.equal(
    (s.calls[0].options?.headers as Record<string, string>).Authorization,
    "Bearer private-test-token",
  );
  const body = JSON.parse(String(s.calls[0].options?.body));
  assert.equal(body.to, "573000000000");
  assert.equal(body.template.name, "jaspers_market_order_confirmation_v1");
  assert.equal(body.template.language.code, "en_US");
  assert.deepEqual(
    body.template.components[0].parameters.map((p: { text: string }) => p.text),
    ["John Doe", "123456", "Nov 6, 2026"],
  );
});

Deno.test("review denies unauthorized, other tenant, missing secrets and throttled sends", async () => {
  const denied = setup();
  denied.deny();
  assert.equal((await denied.request()).status, 403);
  assert.equal(denied.calls.length, 0);
  const cross = setup();
  assert.equal(
    (await cross.request("send", {
      tenant_id: "10000000-0000-0000-0000-000000000002",
    })).status,
    403,
  );
  assert.equal(cross.calls.length, 0);
  const missing = setup();
  delete missing.secrets.WHATSAPP_REVIEW_ACCESS_TOKEN;
  assert.equal((await missing.request()).status, 409);
  assert.equal(missing.calls.length, 0);
  const throttled = setup();
  throttled.throttle();
  assert.equal((await throttled.request()).status, 429);
  assert.equal(throttled.calls.length, 0);
  const invalid = setup();
  assert.equal((await invalid.request("bad")).status, 400);
});

Deno.test("review errors never echo Meta's raw payload or return false success", async () => {
  const s = setup();
  s.respond({ error: { code: 190, message: "private-test-token" } }, 400);
  const response = await s.request();
  assert.equal(response.status, 400);
  const text = await response.text();
  assert.ok(text.includes("190"));
  assert.ok(!text.includes("private-test-token"));
  s.respond({ messages: [] });
  assert.equal((await s.request()).status, 502);
});
