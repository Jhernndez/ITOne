import assert from "node:assert/strict";
import { messageImage } from "../whatsapp-message-image/index.ts";
import { normalizeMessages } from "./whatsapp_webhook.ts";
import { PGlite } from "npm:@electric-sql/pglite";
import { whatsappWebhook } from "../whatsapp-webhook/index.ts";

Deno.test("signed mobile image echoes persist before acknowledgement and retry media failures", async () => {
  const original = globalThis.fetch;
  const env = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_SERVICE_ROLE_KEY: "service",
    META_APP_SECRET: "webhook-test-secret",
  };
  const before = new Map(
    [...Object.keys(env), "WHATSAPP_BOT_WORKER_SECRET"].map(
      (key) => [key, Deno.env.get(key)],
    ),
  );
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  Deno.env.delete("WHATSAPP_BOT_WORKER_SECRET");
  let fail = false, ingested = 0, updated = 0;
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init), url = new URL(request.url);
    if (url.pathname.includes("read_platform_meta_configuration")) {
      return Response.json(null);
    }
    if (url.pathname.includes("whatsapp_accounts")) {
      return Response.json({
        id: "account",
        tenant_id: "tenant",
        business_account_id: "waba",
      });
    }
    if (url.pathname.includes("ingest_whatsapp_messages")) {
      const body = await request.json();
      assert.equal(body.p_account_id, "account");
      assert.equal(body.p_messages[0].source, "business_app");
      assert.equal(body.p_messages[0].direction, "outbound");
      ingested++;
      return Response.json(null);
    }
    if (url.pathname.includes("whatsapp_messages")) {
      assert.equal(url.searchParams.get("tenant_id"), "eq.tenant");
      assert.equal(url.searchParams.get("whatsapp_account_id"), "eq.account");
      assert.equal((await request.json()).media_id, "123456");
      updated++;
      return fail
        ? Response.json({ code: "failure" }, { status: 500 })
        : Response.json(null);
    }
    throw new Error("Unexpected webhook fetch");
  };
  const raw = JSON.stringify({
    entry: [{
      id: "waba",
      changes: [{
        field: "smb_message_echoes",
        value: {
          metadata: { phone_number_id: "456789" },
          message_echoes: [{
            id: "echo",
            to_user_id: "US.test",
            timestamp: "1795640000",
            type: "image",
            image: { id: "123456", mime_type: "image/jpeg" },
          }],
        },
      }],
    }],
  });
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.META_APP_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = [
    ...new Uint8Array(
      await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)),
    ),
  ].map((value) => value.toString(16).padStart(2, "0")).join("");
  const run = () =>
    whatsappWebhook(
      new Request("https://example.test", {
        method: "POST",
        headers: { "X-Hub-Signature-256": `sha256=${signature}` },
        body: raw,
      }),
    );
  try {
    assert.equal((await run()).status, 200);
    assert.equal(ingested, 1);
    assert.equal(updated, 1);
    fail = true;
    assert.equal((await run()).status, 500);
    assert.equal(updated, 2);
  } finally {
    globalThis.fetch = original;
    for (const [key, value] of before) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});

Deno.test("image migration preserves messages and constrains media IDs", async () => {
  const db = new PGlite();
  try {
    await db.exec(
      "create table whatsapp_messages(id integer primary key); insert into whatsapp_messages values(1);",
    );
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../../migrations/20261125234000_whatsapp_image_media.sql",
          import.meta.url,
        ),
      ),
    );
    assert.equal(
      (await db.query("select media_id from whatsapp_messages")).rows.length,
      1,
    );
    await db.exec(
      "update whatsapp_messages set media_id='123456',media_mime_type='image/jpeg'",
    );
    await assert.rejects(
      db.exec("update whatsapp_messages set media_id='invalid/path'"),
      /check constraint/,
    );
  } finally {
    await db.close();
  }
});

Deno.test("image and mobile echo normalization retain media identity without changing direction", () => {
  const [message] = normalizeMessages("smb_message_echoes", {
    message_echoes: [{
      id: "echo",
      to_user_id: "US.test",
      type: "image",
      image: { id: "123456", mime_type: "image/jpeg" },
    }],
  });
  assert.equal(message.source, "business_app");
  assert.equal(message.direction, "outbound");
  assert.equal(message.media_id, "123456");
});

Deno.test("image endpoint scopes message/account, uses server credentials and rejects forbidden downloads", async () => {
  const original = globalThis.fetch;
  const env = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_ANON_KEY: "anon",
    SUPABASE_SERVICE_ROLE_KEY: "service",
  };
  const before = Object.keys(env).map((key) => [key, Deno.env.get(key)]);
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  let role = "operator",
    disabled = false,
    found = true,
    permitted = true,
    imageUrl = "https://lookaside.fbsbx.com/media";
  let size = 3, bytes = 3, downloads = 0;
  globalThis.fetch = (input, init) => {
    const url = String(input);
    let data: unknown;
    if (url.includes("/auth/v1/user")) data = { id: "user" };
    else if (url.includes("/is_current_user_disabled")) data = disabled;
    else if (url.includes("/current_tenant_role")) data = role;
    else if (url.includes("/can_access_whatsapp_number")) data = permitted;
    else if (url.includes("/whatsapp_messages")) {
      assert.ok(url.includes("tenant_id=eq.tenant"));
      data = found
        ? {
          media_id: "123456",
          message_type: "image",
          whatsapp_account_id: "account",
        }
        : null;
    } else if (url.includes("/whatsapp_accounts")) {
      assert.ok(url.includes("tenant_id=eq.tenant"));
      data = url.includes("access_token")
        ? {
          access_token: "private-account-token",
          onboarding_mode: "coexistence",
        }
        : { phone_number_id: "456789", status: "active" };
    } else if (url.includes("graph.facebook.com")) {
      data = { url: imageUrl, mime_type: "image/jpeg", file_size: size };
    } else if (url.includes("lookaside.fbsbx.com")) {
      downloads++;
      assert.equal(
        new Headers(init?.headers).get("Authorization"),
        "Bearer private-account-token",
      );
      assert.equal(init?.redirect, "error");
      return Promise.resolve(
        new Response(new Uint8Array(bytes), {
          headers: { "content-type": "image/jpeg" },
        }),
      );
    } else throw new Error(`Unexpected URL ${url}`);
    return Promise.resolve(Response.json(data));
  };
  const run = () =>
    messageImage(
      new Request("https://example.test", {
        method: "POST",
        headers: { Authorization: "Bearer test" },
        body: JSON.stringify({ tenant_id: "tenant", message_id: "message" }),
      }),
    );
  try {
    assert.equal(
      (await messageImage(
        new Request("https://example.test", { method: "POST" }),
      )).status,
      401,
    );
    let response = await run();
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.base64, "AAAA");
    assert.ok(!JSON.stringify(data).includes("private-account-token"));
    assert.equal(response.headers.get("cache-control"), "no-store");
    role = "viewer";
    assert.equal((await run()).status, 403);
    role = "operator";
    disabled = true;
    assert.equal((await run()).status, 403);
    disabled = false;
    found = false;
    assert.equal((await run()).status, 404);
    found = true;
    permitted = false;
    assert.equal((await run()).status, 403);
    assert.equal(downloads, 1);
    permitted = true;
    imageUrl = "https://internal.invalid/file";
    assert.equal((await run()).status, 502);
    assert.equal(downloads, 1);
    imageUrl = "https://lookaside.fbsbx.com/media";
    size = 6 * 1024 * 1024;
    assert.equal((await run()).status, 413);
    assert.equal(downloads, 1);
    size = 3;
    bytes = 6 * 1024 * 1024;
    response = await run();
    assert.equal(response.status, 413);
  } finally {
    globalThis.fetch = original;
    for (const [key, value] of before) {
      if (value === undefined) Deno.env.delete(key!);
      else Deno.env.set(key!, value);
    }
  }
});
