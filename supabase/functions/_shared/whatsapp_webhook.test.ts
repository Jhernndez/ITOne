import assert from "node:assert/strict";
import test from "node:test";
import { historyState, isoTimestamp, normalizeMessages, validSignature } from "./whatsapp_webhook.ts";

test("business app echoes are outbound and preserve BSUID-only contacts", () => {
  const [message] = normalizeMessages("smb_message_echoes", {
    message_echoes: [{
      id: "echo-1", to_user_id: "US.test", timestamp: "1700000000",
      type: "text", text: { body: "Desde el celular" },
    }],
  });
  assert.equal(message.direction, "outbound");
  assert.equal(message.source, "business_app");
  assert.equal(message.user_id, "US.test");
  assert.equal(message.phone_number, null);
  assert.equal(message.body, "Desde el celular");
});

test("history uses thread identity, provider time and original direction", () => {
  const messages = normalizeMessages("history", {
    metadata: { display_phone_number: "+57 300 0000000" },
    history: [{
      metadata: { phase: 1, chunk_order: 2, progress: 80 },
      threads: [{
        id: "573110000000", context: { user_id: "US.test" },
        messages: [
          { id: "in", from: "573110000000", timestamp: "1700000000", type: "text", text: { body: "Hola" } },
          {
            id: "out", from: "573000000000", timestamp: "1700000001", type: "text",
            text: { body: "Respuesta" }, history_context: { status: "READ" },
          },
        ],
      }],
    }],
  });
  assert.equal(messages[0].direction, "inbound");
  assert.equal(messages[1].direction, "outbound");
  assert.equal(messages[1].delivery_status, "read");
  assert.equal(messages[0].source, "history");
  assert.equal(messages[0].timestamp, "2023-11-14T22:13:20.000Z");
});

test("history supports missing phone numbers and supplementary media without live notifications", () => {
  const [message] = normalizeMessages("history", {
    history: [{
      threads: [{
        context: { user_id: "US.test" },
        messages: [{ id: "user", from_user_id: "US.test", type: "audio" }],
      }],
    }],
  });
  assert.equal(message.user_id, "US.test");
  assert.equal(message.direction, "inbound");
  const [media] = normalizeMessages("history", {
    messages: [{ id: "media", from_user_id: "US.test", type: "image", image: { caption: "Foto" } }],
  });
  assert.equal(media.source, "history");
});

test("invalid identities fail explicitly and invalid timestamps cannot throw RangeError", () => {
  assert.throws(() => normalizeMessages("messages", { messages: [{ id: "missing-contact", type: "text" }] }));
  assert.equal(isoTimestamp("9999999999999999999999"), null);
  assert.equal(isoTimestamp("invalid"), null);
});

test("edits and revokes refer to the original message", () => {
  const [edit] = normalizeMessages("smb_message_echoes", {
    message_echoes: [{
      id: "edit", to: "+573110000000", type: "edit",
      edit: { original_message_id: "original", message: { type: "text", text: { body: "Editado" } } },
    }],
  });
  assert.equal(edit.original_message_id, "original");
  assert.equal(edit.body, "Editado");
});

test("history reports consent denial, completion, and chunk progress", () => {
  assert.deepEqual(historyState({ history: [{ metadata: { progress: 80 } }, { metadata: { progress: 100 } }] }),
    { progress: 100, error: null, declined: false });
  const denied = historyState({ history: [{ errors: [{ code: 2593109, error_data: { details: "No autorizado" } }] }] });
  assert.equal(denied.declined, true);
  assert.equal(denied.error, "No autorizado");
});

test("webhook signatures reject spoofing and body modification", async () => {
  const raw = '{"entry":[]}';
  const secret = "test-only-secret";
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
  const signature = "sha256=" + Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  assert.equal(await validSignature(raw, signature, secret), true);
  assert.equal(await validSignature(raw + " ", signature, secret), false);
  assert.equal(await validSignature(raw, null, secret), false);
});
