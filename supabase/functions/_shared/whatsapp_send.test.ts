import assert from "node:assert/strict";
import { sendWhatsAppMessage } from "../send-whatsapp-message/index.ts";

const tenant = "company-one";
const account = "account-one";

async function fixture(
  contact: Record<string, unknown>,
  run: (sent: Record<string, unknown>[]) => Promise<void>,
) {
  const originalFetch = globalThis.fetch;
  const env = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    SUPABASE_ANON_KEY: "test-anon",
  };
  const previous = Object.keys(env).map((key) => [key, Deno.env.get(key)]);
  const sent: Record<string, unknown>[] = [];
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  globalThis.fetch = (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    let data: unknown;
    if (url.includes("/auth/v1/user")) data = { id: "user-one" };
    else if (url.includes("/rpc/current_tenant_role")) data = "tenant_admin";
    else if (url.includes("/rpc/is_current_user_disabled")) data = false;
    else if (url.includes("/rpc/control_whatsapp_bot")) data = null;
    else if (
      url.includes("/whatsapp_conversations") && init?.method !== "PATCH"
    ) {
      assert.ok(url.includes(`tenant_id=eq.${tenant}`));
      assert.ok(url.includes("whatsapp_user_id"));
      data = {
        id: "conversation-one",
        tenant_id: tenant,
        whatsapp_account_id: account,
        contact_id: "contact-one",
        whatsapp_accounts: { phone_number_id: "123456", status: "active" },
        whatsapp_contacts: contact,
      };
    } else if (url.includes("/whatsapp_accounts")) {
      assert.ok(url.includes(`tenant_id=eq.${tenant}`));
      data = {
        access_token: "account-only-token",
        onboarding_mode: "coexistence",
      };
    } else if (url.includes("/whatsapp_messages") && init?.method !== "POST") {
      data = { provider_timestamp: new Date().toISOString() };
    } else if (url.startsWith("https://graph.facebook.com/")) {
      assert.equal(
        new Headers(init?.headers).get("authorization"),
        "Bearer account-only-token",
      );
      sent.push(JSON.parse(String(init?.body)));
      data = { messages: [{ id: "message-one" }] };
    } else if (
      url.includes("/whatsapp_messages") ||
      url.includes("/whatsapp_conversations")
    ) {
      data = null;
    } else throw new Error(`Unexpected mocked request: ${url}`);
    return Promise.resolve(Response.json(data));
  };
  try {
    await run(sent);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of previous) {
      if (value === undefined) Deno.env.delete(key!);
      else Deno.env.set(key!, value);
    }
  }
}

function request() {
  return new Request("https://example.test", {
    method: "POST",
    headers: { Authorization: "Bearer test" },
    body: JSON.stringify({
      tenant_id: tenant,
      conversation_id: "conversation-one",
      message: "Hola",
    }),
  });
}

Deno.test("manual replies support account-scoped WhatsApp user IDs without phone numbers", async () => {
  await fixture({
    phone_number: null,
    whatsapp_user_id: "user-recipient",
    whatsapp_account_id: account,
    tenant_id: tenant,
  }, async (sent) => {
    const response = await sendWhatsAppMessage(request());
    assert.equal(response.status, 200);
    assert.equal((await response.json()).ok, true);
    assert.equal(sent[0].to, "user-recipient");
  });
});
Deno.test("manual replies preserve phone recipient behavior", async () => {
  await fixture({
    phone_number: "123456789",
    whatsapp_user_id: null,
    whatsapp_account_id: account,
    tenant_id: tenant,
  }, async (sent) => {
    assert.equal((await sendWhatsAppMessage(request())).status, 200);
    assert.equal(sent[0].to, "123456789");
  });
});
for (
  const contact of [
    {
      phone_number: null,
      whatsapp_user_id: "user-recipient",
      whatsapp_account_id: "other-account",
      tenant_id: tenant,
    },
    {
      phone_number: "123456789",
      whatsapp_user_id: null,
      whatsapp_account_id: account,
      tenant_id: "other-company",
    },
    {
      phone_number: "",
      whatsapp_user_id: "",
      whatsapp_account_id: account,
      tenant_id: tenant,
    },
  ]
) {
  Deno.test(`manual replies reject missing or incorrectly scoped recipient: ${JSON.stringify(contact)}`, async () => {
    await fixture(contact, async (sent) => {
      const response = await sendWhatsAppMessage(request());
      assert.equal(response.status, 409);
      assert.equal(sent.length, 0);
    });
  });
}
