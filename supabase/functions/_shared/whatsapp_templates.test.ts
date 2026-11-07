import assert from "node:assert/strict";
import {
  parseTemplate,
  templateComponents,
  TemplateError,
  templatesHandler,
} from "./whatsapp_templates.ts";

const tenant = "10000000-0000-0000-0000-000000000001";
const input = () => ({
  name: "solicitud",
  language: "es",
  category: "UTILITY",
  header: "Solicitud {{1}}",
  header_example: "123",
  body: "Hola {{1}}, solicitud {{2}} recibida.",
  body_examples: ["Ana", "123"],
  footer: "ITONE",
  buttons: [{
    type: "URL",
    text: "Consultar",
    value: "https://example.com/solicitud",
  }],
});
Deno.test("templates map text components and numeric examples to Meta payload", () => {
  const parsed = parseTemplate(input());
  const components = templateComponents(parsed);
  assert.deepEqual(components[0], {
    type: "HEADER",
    format: "TEXT",
    text: "Solicitud {{1}}",
    example: { header_text: ["123"] },
  });
  assert.deepEqual(components[1], {
    type: "BODY",
    text: parsed.body,
    example: { body_text: [["Ana", "123"]] },
  });
  assert.deepEqual(components[3], {
    type: "BUTTONS",
    buttons: [{
      type: "URL",
      text: "Consultar",
      url: "https://example.com/solicitud",
    }],
  });
  for (
    const override of [
      { name: "Bad name" },
      { category: "AUTHENTICATION" },
      { body: "{{2}}" },
      { body: "Hola {{nombre}}" },
      { body_examples: ["Ana"] },
      { footer: "{{1}}" },
      { header: "{{1}} {{2}}" },
      { header_example: "" },
      { buttons: [{ type: "URL", text: "Ir", value: "http://example.com" }] },
      {
        buttons: [{
          type: "URL",
          text: "Ir",
          value: "https://example.com/{{1}}",
        }],
      },
      {
        buttons: [{ type: "QUICK_REPLY", text: "Sí", value: "" }, {
          type: "URL",
          text: "Ir",
          value: "https://example.com",
        }],
      },
    ]
  ) {
    assert.throws(
      () => parseTemplate({ ...input(), ...override }),
      TemplateError,
    );
  }
});
function setup() {
  const requests: { url: string; init?: RequestInit }[] = [];
  let owned = true, denied = false, token: string | null = "secret";
  let failure = false;
  let override: Record<string, unknown> | undefined;
  const handler = templatesHandler({
    version: "v25.0",
    authorize: async () => {
      if (denied) throw new TemplateError("No autorizado", 403);
      return [{
        id: "account",
        business_account_id: "123",
        access_token: token,
        name: "Empresa",
      }];
    },
    fetch: (url, init) => {
      requests.push({ url: String(url), init });
      let data: object;
      if (override) data = override;
      else if (failure) data = { error: { code: 190, message: "secret" } };
      else if (
        init?.method === "DELETE" ||
        (init?.method === "POST" && String(url).endsWith("/999"))
      ) data = { success: true };
      else if (init?.method === "POST") data = { id: "999", status: "PENDING" };
      else {data = {
          data: owned
            ? [{
              id: "999",
              name: "solicitud",
              category: "UTILITY",
              language: "es",
            }]
            : [],
          paging: {
            next: "https://graph.facebook.com/with-secret",
            cursors: { after: "cursor" },
          },
        };}
      return Promise.resolve(
        new Response(JSON.stringify(data), { status: failure ? 400 : 200 }),
      );
    },
  });
  const request = (action: string, extra = {}) =>
    handler(
      new Request("https://example.test", {
        method: "POST",
        body: JSON.stringify({
          tenant_id: tenant,
          account_id: "account",
          action,
          ...extra,
        }),
      }),
    );
  return {
    requests,
    request,
    unown: () => {
      owned = false;
    },
    deny: () => {
      denied = true;
    },
    noToken: () => {
      token = null;
    },
    fail: () => {
      failure = true;
    },
    respondWith: (response: Record<string, unknown>) => {
      override = response;
    },
  };
}
Deno.test("template operations scope credentials, redact tokens and reject foreign template IDs", async () => {
  const s = setup();
  const accounts = await (await s.request("accounts")).text();
  assert.ok(!accounts.includes("secret"));
  const list = await (await s.request("list", { after: "abc" })).json();
  assert.equal(list.after, "cursor");
  assert.ok(!JSON.stringify(list).includes("with-secret"));
  assert.ok(s.requests[0].url.includes("after=abc"));
  const created = await s.request("create", {
    template: input(),
    token: "attacker",
    waba_id: "attacker",
  });
  assert.equal(created.status, 200);
  assert.equal(
    s.requests[1].url,
    "https://graph.facebook.com/v25.0/123/message_templates",
  );
  assert.equal(
    (s.requests[1].init?.headers as Record<string, string>).Authorization,
    "Bearer secret",
  );
  assert.equal(
    (await s.request("edit", {
      template_id: "999",
      name: "solicitud",
      template: input(),
    })).status,
    200,
  );
  assert.equal(
    (await s.request("delete", { template_id: "999", name: "solicitud" }))
      .status,
    200,
  );
  assert.ok(s.requests.at(-1)?.url.includes("hsm_id=999"));
  const before = s.requests.length;
  s.unown();
  assert.equal(
    (await s.request("delete", { template_id: "999", name: "solicitud" }))
      .status,
    404,
  );
  assert.equal(s.requests.length, before + 1);
});
Deno.test("template endpoint denies unauthenticated, foreign accounts and missing own credentials", async () => {
  const denied = setup();
  denied.deny();
  assert.equal((await denied.request("accounts")).status, 403);
  assert.equal(denied.requests.length, 0);
  const foreign = setup();
  assert.equal(
    (await foreign.request("list", { account_id: "foreign" })).status,
    403,
  );
  assert.equal(foreign.requests.length, 0);
  const missing = setup();
  missing.noToken();
  assert.equal((await missing.request("list")).status, 409);
  const failure = setup();
  failure.fail();
  const response = await failure.request("create", { template: input() });
  assert.equal(response.status, 400);
  const text = await response.text();
  assert.ok(!text.includes("secret"));
  assert.ok(text.includes("190"));
});
Deno.test("edit cannot rename or change immutable language/category", async () => {
  const s = setup();
  assert.equal(
    (await s.request("edit", {
      template_id: "999",
      name: "solicitud",
      template: { ...input(), language: "en_US" },
    })).status,
    400,
  );
  assert.equal(s.requests.length, 1);
});

Deno.test("template validation enforces content limits and button payloads", () => {
  const plain = {
    ...input(),
    header: "x".repeat(60),
    body: "x".repeat(1024),
    body_examples: [],
  };
  assert.equal(parseTemplate(plain).body.length, 1024);
  for (
    const extra of [
      { header: "x".repeat(61) },
      { body: "x".repeat(1025) },
      { footer: "x".repeat(61) },
      {
        buttons: Array.from(
          { length: 4 },
          (_, i) => ({ type: "QUICK_REPLY", text: `Boton ${i}`, value: "" }),
        ),
      },
      {
        buttons: [{
          type: "PHONE_NUMBER",
          text: "Llamar",
          value: "3001234567",
        }],
      },
    ]
  ) assert.throws(() => parseTemplate({ ...plain, ...extra }), TemplateError);
  for (
    const [type, value, expected] of [
      ["QUICK_REPLY", "", { type: "QUICK_REPLY", text: "Continuar" }],
      ["PHONE_NUMBER", "+573001234567", {
        type: "PHONE_NUMBER",
        text: "Continuar",
        phone_number: "+573001234567",
      }],
    ] as const
  ) {
    const components = templateComponents(
      parseTemplate({
        ...plain,
        buttons: [{ type, text: "Continuar", value }],
      }),
    );
    assert.deepEqual(components.at(-1), {
      type: "BUTTONS",
      buttons: [expected],
    });
  }
});

Deno.test("ambiguous Meta results never become confirmed mutations or assumed approval", async () => {
  const s = setup();
  s.respondWith({});
  assert.equal((await s.request("create", { template: input() })).status, 502);
  s.respondWith({ id: "999" });
  const created = await (await s.request("create", { template: input() }))
    .json();
  assert.equal(created.status, "No informado por Meta");
  s.respondWith({
    data: [{
      id: "999",
      name: "solicitud",
      category: "UTILITY",
      language: "es",
    }],
  });
  assert.equal(
    (await s.request("delete", { template_id: "999", name: "solicitud" }))
      .status,
    502,
  );
  assert.equal(
    (await s.request("edit", {
      template_id: "999",
      name: "solicitud",
      template: input(),
    })).status,
    502,
  );
});
