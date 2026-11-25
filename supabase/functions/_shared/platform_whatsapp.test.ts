import assert from "node:assert/strict";
import { platformWhatsAppSettings } from "../platform-whatsapp-settings/index.ts";
import { validateWhatsAppIntegration } from "../validate-whatsapp-integration/index.ts";

const tenant = "10000000-0000-0000-0000-000000000001";

async function fixture(
  run: (state: {
    role: string | null;
    disabled: boolean;
    requests: string[];
    validation: boolean;
    saves: Record<string, unknown>[];
    companyFailure: boolean;
    configuration: Record<string, unknown> | null;
  }) => Promise<void>,
) {
  const keys: Record<string, string> = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_ANON_KEY: "anon",
    SUPABASE_SERVICE_ROLE_KEY: "service",
    META_APP_ID: "app",
    META_APP_SECRET: "never-expose-secret",
    META_WHATSAPP_CONFIG_ID: "config",
    META_GRAPH_VERSION: "v23.0",
    WHATSAPP_VERIFY_TOKEN: "never-expose-webhook-token",
  };
  const originalEnv = new Map(
    Object.keys(keys).map((k) => [k, Deno.env.get(k)]),
  );
  const originalFetch = globalThis.fetch;
  const state = {
    role: "platform_owner" as string | null,
    disabled: false,
    requests: [] as string[],
    validation: false,
    saves: [] as Record<string, unknown>[],
    companyFailure: false,
    configuration: null as Record<string, unknown> | null,
  };
  for (const [k, v] of Object.entries(keys)) Deno.env.set(k, v);
  globalThis.fetch = (input, init) => {
    const url = String(input);
    state.requests.push(url);
    let data: unknown;
    if (url.includes("/auth/v1/user")) {
      data = {
        id: tenant,
        aud: "authenticated",
        created_at: "2026-01-01T00:00:00Z",
      };
    } else if (url.includes("/rpc/is_current_user_disabled")) {
      data = state.disabled;
    } else if (url.includes("/platform_memberships")) {
      data = state.role ? { role: state.role } : null;
    } else if (url.includes("/rpc/read_platform_meta_configuration")) {
      data = state.configuration;
    } else if (url.includes("/rpc/write_platform_meta_configuration")) {
      state.saves.push(JSON.parse(String(init?.body)));
      data = null;
    } else if (url.includes("/tenant_integrations")) {
      data = {
        id: "integration",
        status: "error",
        metadata: {
          business_account_id: "123",
          phone_number_id: "456",
          onboarding_mode: "coexistence",
          unexpected_secret: "never-expose-legacy-metadata",
        },
      };
    } else if (url.includes("/whatsapp_accounts")) {
      const selected = new URL(url).searchParams.get("select") ?? "";
      assert.equal(selected.includes("access_token"), state.validation);
      assert.ok(!selected.includes("*"));
      assert.ok(new URL(url).searchParams.get("tenant_id")?.includes(tenant));
      data = state.validation
        ? {
          access_token: "account-token",
          onboarding_mode: "coexistence",
        }
        : [{
          id: "account",
          name: "Empresa",
          business_account_id: "123",
          phone_number_id: "456",
        }];
    } else if (url.startsWith("https://graph.facebook.com/")) {
      if (!state.validation) {
        data = url.includes("/subscriptions")
          ? {
            data: [{
              object: "whatsapp_business_account",
              active: true,
              callback_url:
                "https://example.test/functions/v1/whatsapp-webhook",
              fields: [{ name: "messages" }],
            }],
          }
          : { id: new URL(url).pathname.split("/")[2], name: "ITONE" };
        return Promise.resolve(Response.json(data));
      }
      assert.equal(
        new Headers(init?.headers).get("Authorization"),
        "Bearer account-token",
      );
      data = {
        id: "456",
        is_on_biz_app: true,
        platform_type: "CLOUD_API",
        health_status: {
          entities: [{
            entity_type: "PHONE_NUMBER",
            can_send_message: "BLOCKED",
          }],
        },
      };
    } else if (url.includes("/tenants")) {
      if (state.companyFailure) {
        return Promise.resolve(
          Response.json({
            code: "42501",
            message: "permission denied for table tenants",
          }, { status: 403 }),
        );
      }
      data = [{ id: tenant, name: "Empresa" }];
    } else {
      throw new Error(`Unexpected request: ${url}`);
    }
    return Promise.resolve(
      new Response(JSON.stringify(data), {
        headers: { "Content-Type": "application/json" },
      }),
    );
  };
  try {
    await run(state);
  } finally {
    globalThis.fetch = originalFetch;
    for (const [k, v] of originalEnv) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  }
}

function request(action: string, authenticated = true) {
  return new Request("https://example.test/function", {
    method: "POST",
    headers: authenticated ? { Authorization: "Bearer user-session" } : {},
    body: JSON.stringify({ action, tenant_id: tenant }),
  });
}

Deno.test("internal settings and validation reject tenants, other platform roles and disabled owners", async () => {
  await fixture(async (s) => {
    for (
      const handler of [platformWhatsAppSettings, validateWhatsAppIntegration]
    ) {
      assert.equal(
        (await handler(request("configuration", false))).status,
        401,
      );
      for (
        const role of [
          null,
          "tenant_admin",
          "platform_admin",
          "platform_support",
        ]
      ) {
        s.role = role;
        s.requests = [];
        assert.equal((await handler(request("configuration"))).status, 403);
        assert.ok(
          !s.requests.some((url) =>
            url.includes("/tenant_integrations") ||
            url.includes("graph.facebook")
          ),
        );
      }
      s.role = "platform_owner";
      s.disabled = true;
      assert.equal((await handler(request("configuration"))).status, 403);
      s.disabled = false;
    }
  });
});

Deno.test("owner configuration exposes identifiers and secret readiness but never secrets", async () => {
  await fixture(async () => {
    const response = await platformWhatsAppSettings(request("configuration"));
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.app_id, "app");
    assert.equal(data.config_id, "config");
    assert.equal(data.app_secret_configured, true);
    assert.equal(data.webhook_verify_token_configured, true);
    assert.ok(!JSON.stringify(data).includes("never-expose"));
  });
});

Deno.test("owner can validate a tenant without a tenant grant and see Meta restrictions", async () => {
  await fixture(async (s) => {
    s.validation = true;
    const response = await validateWhatsAppIntegration(request("validate"));
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.status, "restricted");
    assert.equal(data.blocked_entities[0].can_send_message, "BLOCKED");
    assert.ok(!s.requests.some((url) => url.includes("current_tenant_role")));
    assert.ok(
      s.requests.some((url) => url.startsWith("https://graph.facebook.com/")),
    );
    assert.ok(!JSON.stringify(data).includes("account-token"));
  });
});

Deno.test("owner diagnostics scope account queries and allowlist legacy metadata", async () => {
  await fixture(async () => {
    const response = await platformWhatsAppSettings(request("diagnostics"));
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.integration.phone_number_id, "456");
    assert.equal(data.accounts.length, 1);
    assert.ok(!JSON.stringify(data).includes("never-expose"));
    const tenants = await (await platformWhatsAppSettings(request("tenants")))
      .json();
    assert.equal(tenants.tenants[0].id, tenant);
    assert.equal(
      (await platformWhatsAppSettings(request("unsupported"))).status,
      400,
    );
  });
});

Deno.test("owner app check returns safe credentials and webhook status, distinct from number validation", async () => {
  await fixture(async () => {
    const response = await platformWhatsAppSettings(request("check_app"));
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.app_credentials_valid, true);
    assert.equal(data.webhook_matches, true);
    assert.equal(data.webhook_active, true);
    assert.deepEqual(data.webhook_fields, ["messages"]);
    assert.ok(!JSON.stringify(data).includes("never-expose"));
  });
});
Deno.test("configuration saves only for owner, verifies app first and leaves missing secrets unchanged", async () => {
  await fixture(async (s) => {
    const saveRequest = () =>
      new Request("https://example.test", {
        method: "POST",
        headers: { Authorization: "Bearer test" },
        body: JSON.stringify({
          action: "save_configuration",
          app_id: "2169281667133692",
          config_id: "3860984100732128",
          app_secret: "new-secret-not-returned",
        }),
      });
    s.role = "tenant_admin";
    assert.equal((await platformWhatsAppSettings(saveRequest())).status, 403);
    assert.equal(s.saves.length, 0);
    s.role = "platform_owner";
    const response = await platformWhatsAppSettings(saveRequest());
    assert.equal(response.status, 200);
    assert.equal(s.saves.length, 1);
    assert.equal(s.saves[0].p_verify_token, null);
    assert.ok(!JSON.stringify(await response.json()).includes("new-secret"));
    const bad = new Request("https://example.test", {
      method: "POST",
      headers: { Authorization: "Bearer test" },
      body: JSON.stringify({
        action: "save_configuration",
        app_id: "2169281667133692",
        config_id: "bad",
      }),
    });
    assert.equal((await platformWhatsAppSettings(bad)).status, 400);
    assert.equal(s.saves.length, 1);
  });
});
Deno.test("company permission failure is explicit and does not erase otherwise available configuration", async () => {
  await fixture(async (s) => {
    s.companyFailure = true;
    const response = await platformWhatsAppSettings(request("tenants"));
    assert.equal(response.status, 503);
    assert.match((await response.json()).error, /listar las empresas/);
    assert.equal(
      (await platformWhatsAppSettings(request("configuration"))).status,
      200,
    );
  });
});

Deno.test("persisted platform overrides take priority but never expose decrypted credentials", async () => {
  await fixture(async (s) => {
    s.configuration = {
      app_id: "123456",
      config_id: "654321",
      app_secret: "vault-secret-not-returned",
      verify_token: "vault-webhook-not-returned",
    };
    const response = await platformWhatsAppSettings(request("configuration"));
    const data = await response.json();
    assert.equal(data.app_id, "123456");
    assert.equal(data.config_id, "654321");
    assert.equal(data.configuration_source, "platform");
    assert.equal(data.app_secret_configured, true);
    assert.equal(data.webhook_verify_token_configured, true);
    assert.ok(!JSON.stringify(data).includes("vault-secret"));
    assert.ok(!JSON.stringify(data).includes("vault-webhook"));
    s.disabled = true;
    assert.equal(
      (await platformWhatsAppSettings(request("save_configuration"))).status,
      403,
    );
    assert.equal(
      (await platformWhatsAppSettings(request("check_app"))).status,
      403,
    );
  });
});
Deno.test("owner oversized configuration input is rejected before secrets or Meta access", async () => {
  await fixture(async (s) => {
    const response = await platformWhatsAppSettings(
      new Request("https://example.test", {
        method: "POST",
        headers: { Authorization: "Bearer test" },
        body: JSON.stringify({
          action: "save_configuration",
          app_secret: "x".repeat(9000),
        }),
      }),
    );
    assert.equal(response.status, 413);
    assert.equal(s.saves.length, 0);
    assert.ok(
      !s.requests.some((url) => url.startsWith("https://graph.facebook.com/")),
    );
  });
});
