const assert = require("node:assert/strict");
const { test } = require("node:test");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function environment() {
  const listeners = new Set();
  let callback;
  let options;
  const window = {
    FB: {
      init() {},
      login(cb, opts) { callback = cb; options = opts; },
    },
    addEventListener(type, cb) { if (type === "message") listeners.add(cb); },
    removeEventListener(type, cb) { if (type === "message") listeners.delete(cb); },
  };
  const context = { window, setTimeout: () => 1, clearTimeout() {} };
  vm.runInNewContext(readFileSync(path.join(__dirname, "..", "web", "whatsapp_signup.js"), "utf8"), context);
  return {
    window,
    callback: () => callback,
    options: () => options,
    listeners,
    event(event, origin = "https://www.facebook.com") {
      for (const cb of listeners) cb({
        origin, data: JSON.stringify({ type: "WA_EMBEDDED_SIGNUP", event, data: { waba_id: "123" } }),
      });
    },
  };
}

test("signup waits for both code and coexistence completion, in either order", async () => {
  for (const codeFirst of [true, false]) {
    const env = environment();
    await env.window.itoneWhatsAppPrepare("app", "v23.0");
    const result = env.window.itoneWhatsAppConnect("config");
    assert.equal(env.options().extras.featureType, "whatsapp_business_app_onboarding");
    if (codeFirst) env.callback()({ authResponse: { code: "test-code" } });
    env.event("FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING");
    if (!codeFirst) env.callback()({ authResponse: { code: "test-code" } });
    assert.equal(JSON.parse(await result).waba_id, "123");
    assert.equal(env.listeners.size, 0);
  }
});

test("signup ignores lookalike Facebook origins", async () => {
  const env = environment();
  await env.window.itoneWhatsAppPrepare("app", "v23.0");
  const result = env.window.itoneWhatsAppConnect("config");
  env.event("FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING", "https://evilfacebook.com");
  env.callback()({ authResponse: { code: "test-code" } });
  let done = false;
  result.then(() => { done = true; });
  await Promise.resolve();
  assert.equal(done, false);
  env.event("FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING");
  await result;
});

test("standard API onboarding and cancellation cannot look like coexistence success", async () => {
  for (const event of ["FINISH", "CANCEL", "ERROR"]) {
    const env = environment();
    await env.window.itoneWhatsAppPrepare("app", "v23.0");
    const result = env.window.itoneWhatsAppConnect("config");
    env.event(event);
    await assert.rejects(result);
    assert.equal(env.listeners.size, 0);
  }
});
