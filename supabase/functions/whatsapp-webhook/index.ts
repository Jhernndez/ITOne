import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { json } from "../_shared/whatsapp.ts";
import {
  historyState, normalizeMessages, object, objects, validSignature,
} from "../_shared/whatsapp_webhook.ts";

Deno.serve(async (request) => {
  if (request.method === "GET") {
    const url = new URL(request.url);
    const verifyToken = Deno.env.get("WHATSAPP_VERIFY_TOKEN");
    const challenge = url.searchParams.get("hub.challenge");
    if (verifyToken && url.searchParams.get("hub.mode") === "subscribe" &&
        url.searchParams.get("hub.verify_token") === verifyToken && challenge) {
      return new Response(challenge);
    }
    return new Response("Webhook verification failed", { status: 403 });
  }
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const appSecret = Deno.env.get("META_APP_SECRET");
    if (!url || !serviceKey || !appSecret) {
      throw new Error("Supabase and META_APP_SECRET must be configured");
    }
    const raw = await request.text();
    if (!await validSignature(raw, request.headers.get("X-Hub-Signature-256"), appSecret)) {
      console.warn("WhatsApp webhook signature rejected");
      return json({ error: "Invalid webhook signature" }, 401);
    }
    const payload = object(JSON.parse(raw));
    const client = createClient(url, serviceKey);
    for (const entry of objects(payload.entry)) {
      for (const change of objects(entry.changes)) {
        const value = object(change.value);
        const phoneNumberId = object(value.metadata).phone_number_id;
        if (typeof phoneNumberId !== "string") continue;
        const { data: account, error: accountError } = await client
          .from("whatsapp_accounts").select("id, tenant_id, business_account_id")
          .eq("phone_number_id", phoneNumberId).eq("status", "active").maybeSingle();
        if (accountError) throw accountError;
        if (!account) {
          // Return a retryable response during onboarding rather than lose a
          // chunk delivered between Meta subscription and account persistence.
          console.warn("Unmapped WhatsApp phone number", { phoneNumberId });
          return json({ error: "WhatsApp account is not mapped yet" }, 503);
        }
        if (entry.id !== account.business_account_id) {
          throw new Error("Webhook account does not match mapped business account");
        }
        for (const status of objects(value.statuses)) {
          const detail = objects(status.errors)[0];
          const errorCode = detail?.code != null ? String(detail.code) : null;
          const errorMessage = detail
            ? [detail.title, detail.message, object(detail.error_data).details]
              .filter((part) => typeof part === "string" && part.length > 0).join(": ")
            : null;
          console.log("WhatsApp message status received", {
            phoneNumberId, messageId: status.id, status: status.status, errorCode, errorMessage,
          });
          if (typeof status.id !== "string" || typeof status.status !== "string") continue;
          const { error } = await client.from("whatsapp_messages").update({
            delivery_status: ["sent", "delivered", "read", "failed"].includes(status.status)
              ? status.status : "accepted",
            delivery_error_code: errorCode,
            delivery_error: errorMessage,
          }).eq("provider_message_id", status.id).eq("whatsapp_account_id", account.id);
          if (error) throw error;
        }
        const messages = normalizeMessages(String(change.field), value);
        // Bounded RPC batches avoid a network round-trip per historical message.
        // Commit before acknowledging so Meta retries recover partial ingestion.
        for (let offset = 0; offset < messages.length; offset += 200) {
          const { error } = await client.rpc("ingest_whatsapp_messages", {
            p_account_id: account.id, p_messages: messages.slice(offset, offset + 200),
          });
          if (error) throw error;
        }
        const stateSync = objects(value.state_sync);
        if (stateSync.length) {
          const { error } = await client.rpc("sync_whatsapp_contacts", {
            p_account_id: account.id, p_contacts: stateSync,
          });
          if (error) throw error;
        }
        if (change.field === "history") {
          const state = historyState(value);
          const { error } = await client.rpc("update_whatsapp_history_progress", {
            p_account_id: account.id, p_progress: state.progress,
            p_error: state.error, p_declined: state.declined,
          });
          if (error) throw error;
        }
      }
    }
    return json({ ok: true });
  } catch (error) {
    console.error("WhatsApp webhook processing failed", error);
    return json({ error: "WhatsApp webhook processing failed; retry required" }, 500);
  }
});
