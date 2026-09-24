import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function isoTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
  return new Date(Number(value) * 1000).toISOString();
}

// Best-effort extraction of a human-readable body for every message type
// WhatsApp Cloud API can deliver. Media types have no text content, but we
// surface captions/filenames so the UI has something meaningful to show.
// When Meta itself marks a message as "unsupported" it never forwards the
// original content (e.g. view-once media, polls); we surface Meta's own
// explanation from message.errors instead of pretending we can read it.
function extractMessageBody(message: Record<string, any>): string | null {
  switch (message.type) {
    case "text":
      return message.text?.body ?? null;
    case "image":
      return message.image?.caption ?? "[Imagen recibida]";
    case "video":
      return message.video?.caption ?? "[Video recibido]";
    case "audio":
      return "[Audio recibido]";
    case "voice":
      return "[Nota de voz recibida]";
    case "sticker":
      return "[Sticker recibido]";
    case "document":
      return message.document?.caption ??
        (message.document?.filename
          ? `[Documento: ${message.document.filename}]`
          : "[Documento recibido]");
    case "location": {
      const loc = message.location;
      if (!loc) return "[Ubicación recibida]";
      return loc.name
        ? `[Ubicación: ${loc.name}]`
        : `[Ubicación: ${loc.latitude}, ${loc.longitude}]`;
    }
    case "contacts": {
      const names = (message.contacts ?? [])
        .map((entry: any) => entry?.name?.formatted_name)
        .filter((name: unknown) => typeof name === "string");
      return names.length ? `[Contacto: ${names.join(", ")}]` : "[Contacto recibido]";
    }
    case "button":
      return message.button?.text ?? "[Respuesta de botón]";
    case "interactive": {
      const interactive = message.interactive;
      const reply =
        interactive?.button_reply?.title ?? interactive?.list_reply?.title;
      return reply ? `[Respuesta: ${reply}]` : "[Mensaje interactivo recibido]";
    }
    case "reaction":
      return message.reaction?.emoji
        ? `[Reacción: ${message.reaction.emoji}]`
        : "[Reacción recibida]";
    case "system":
      return message.system?.body ?? "[Notificación del sistema]";
    case "unsupported": {
      const detail = Array.isArray(message.errors) ? message.errors[0] : null;
      const reason = detail
        ? [detail.title, detail.message].filter(Boolean).join(": ")
        : null;
      return reason
        ? `[Mensaje no compatible con la API de WhatsApp: ${reason}. Ábrelo desde la app de WhatsApp del número para leerlo.]`
        : "[Mensaje no compatible con la API de WhatsApp. Ábrelo desde la app de WhatsApp del número para leerlo.]";
    }
    default:
      return null;
  }
}

Deno.serve(async (request) => {
  const verifyToken = Deno.env.get("WHATSAPP_VERIFY_TOKEN");
  try {
    if (request.method === "GET") {
      const url = new URL(request.url);
      const mode = url.searchParams.get("hub.mode");
      const token = url.searchParams.get("hub.verify_token");
      const challenge = url.searchParams.get("hub.challenge");
      if (mode === "subscribe" && token === verifyToken && challenge) {
        return new Response(challenge, { status: 200 });
      }
      return new Response("Webhook verification failed", { status: 403 });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", {
        status: 405,
        headers: corsHeaders,
      });
    }

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) {
      throw new Error("Supabase secrets are not configured");
    }

    const payload = await request.json();
    const client = createClient(url, serviceKey);
    console.log("WhatsApp webhook event received", payload);

    for (const entry of payload.entry ?? []) {
      for (const change of entry.changes ?? []) {
        const value = change.value;
        const phoneNumberId = value?.metadata?.phone_number_id;
        if (typeof phoneNumberId !== "string") continue;
        const { data: account, error: accountError } = await client
          .from("whatsapp_accounts")
          .select("id, tenant_id")
          .eq("phone_number_id", phoneNumberId)
          .eq("status", "active")
          .maybeSingle();
        if (accountError) throw accountError;
        if (!account) {
          console.warn("Unmapped WhatsApp phone_number_id", phoneNumberId);
          continue;
        }

        for (const status of value.statuses ?? []) {
          const statusError = Array.isArray(status.errors)
            ? status.errors[0]
            : null;
          const errorCode = statusError?.code != null
            ? String(statusError.code)
            : null;
          const errorMessage = statusError
            ? [statusError.title, statusError.message, statusError.details]
                .filter((part) => typeof part === "string" && part.length > 0)
                .join(": ")
            : null;
          console.log("WhatsApp message status received", {
            phoneNumberId,
            messageId: status.id,
            status: status.status,
            recipientId: status.recipient_id,
            timestamp: status.timestamp,
            errorCode,
            errorMessage,
            errors: status.errors ?? [],
          });
          if (typeof status.id === "string" && typeof status.status === "string") {
            const deliveryStatus = ["sent", "delivered", "read", "failed"].includes(
              status.status,
            )
              ? status.status
              : "accepted";
            const { error: statusError } = await client
              .from("whatsapp_messages")
              .update({
                delivery_status: deliveryStatus,
                delivery_error_code: errorCode,
                delivery_error: errorMessage,
              })
              .eq("provider_message_id", status.id)
              .eq("whatsapp_account_id", account.id);
            if (statusError) console.error("WhatsApp status update failed", statusError);
          }
        }

        for (const message of value.messages ?? []) {
          const sender = message.from;
          const providerMessageId = message.id;
          if (typeof sender !== "string" ||
              typeof providerMessageId !== "string") {
            continue;
          }

          const profileName = value.contacts?.find(
            (contact: { wa_id?: string }) => contact.wa_id === sender,
          )?.profile?.name ?? null;
          const messageTime = isoTimestamp(message.timestamp);
          const contactPayload = {
            tenant_id: account.tenant_id,
            phone_number: sender,
            profile_name: profileName,
            last_message_at: messageTime,
            updated_at: new Date().toISOString(),
          };
          const { data: contact, error: contactError } = await client
            .from("whatsapp_contacts")
            .upsert(contactPayload, { onConflict: "tenant_id,phone_number" })
            .select("id")
            .single();
          if (contactError) throw contactError;

          const { data: conversation, error: conversationError } = await client
            .from("whatsapp_conversations")
            .upsert({
              tenant_id: account.tenant_id,
              whatsapp_account_id: account.id,
              contact_id: contact.id,
              status: "open",
              last_message_at: messageTime,
              updated_at: new Date().toISOString(),
            }, { onConflict: "tenant_id,contact_id,status" })
            .select("id")
            .single();
          if (conversationError) throw conversationError;

          const body = extractMessageBody(message);
          const { error: messageError } = await client
            .from("whatsapp_messages")
            .upsert({
              tenant_id: account.tenant_id,
              conversation_id: conversation.id,
              whatsapp_account_id: account.id,
              provider_message_id: providerMessageId,
              direction: "inbound",
              message_type: message.type ?? "unknown",
              body,
              provider_timestamp: messageTime,
            }, { onConflict: "whatsapp_account_id,provider_message_id" });
          if (messageError) throw messageError;
        }
      }
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("WhatsApp webhook error", error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
