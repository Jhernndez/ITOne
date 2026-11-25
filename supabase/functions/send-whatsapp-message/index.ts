import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  accountToken,
  graphVersion,
  messageRecipient,
  WhatsAppError,
} from "../_shared/whatsapp.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isAllowedRole(role: string | null | undefined) {
  return role === "tenant_admin" || role === "supervisor" ||
    role === "operator";
}

export async function sendWhatsAppMessage(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "WhatsApp sending secrets are not configured" }, 500);
  }

  try {
    const authHeader = request.headers.get("Authorization");
    if (!authHeader) return json({ error: "Authentication required" }, 401);

    const userClient = createClient(
      supabaseUrl,
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) {
      return json({ error: "Authentication required" }, 401);
    }

    const body = await request.json();
    const tenantId = body?.tenant_id;
    const conversationId = body?.conversation_id;
    const messageBody = body?.message;
    if (
      typeof tenantId !== "string" ||
      typeof conversationId !== "string" ||
      typeof messageBody !== "string" ||
      !messageBody.trim() || messageBody.trim().length > 4096
    ) {
      return json({
        error: "tenant_id, conversation_id and message are required",
      }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data: role, error: membershipError } = await userClient.rpc(
      "current_tenant_role",
      { p_tenant_id: tenantId },
    );
    if (membershipError) throw membershipError;
    if (!isAllowedRole(role)) {
      return json(
        { error: "You are not allowed to send WhatsApp messages" },
        403,
      );
    }
    const { data: disabled, error: disabledError } = await userClient.rpc(
      "is_current_user_disabled",
    );
    if (disabledError) throw disabledError;
    if (disabled) return json({ error: "User access is disabled" }, 403);

    const { data: conversation, error: conversationError } = await adminClient
      .from("whatsapp_conversations")
      .select(
        "id, tenant_id, whatsapp_account_id, contact_id, whatsapp_accounts(phone_number_id, status), whatsapp_contacts(phone_number, whatsapp_user_id, whatsapp_account_id, tenant_id)",
      )
      .eq("id", conversationId)
      .eq("tenant_id", tenantId)
      .maybeSingle();
    if (conversationError) throw conversationError;
    if (!conversation) return json({ error: "Conversation not found" }, 404);

    const account = Array.isArray(conversation.whatsapp_accounts)
      ? conversation.whatsapp_accounts[0]
      : conversation.whatsapp_accounts;
    const contact = Array.isArray(conversation.whatsapp_contacts)
      ? conversation.whatsapp_contacts[0]
      : conversation.whatsapp_contacts;
    const phoneNumberId = account?.phone_number_id;
    const recipient = contact?.phone_number?.trim() ||
      (contact?.whatsapp_account_id === conversation.whatsapp_account_id
        ? contact?.whatsapp_user_id?.trim()
        : undefined);
    if (
      account?.status !== "active" ||
      typeof phoneNumberId !== "string" ||
      typeof recipient !== "string" || !recipient ||
      contact?.tenant_id !== tenantId
    ) {
      console.warn("WhatsApp sending identity unavailable", {
        accountActive: account?.status === "active",
        hasRecipient: Boolean(recipient),
        contactTenantMatches: contact?.tenant_id === tenantId,
      });
      return json({
        error:
          "No se encontró una cuenta activa o un destinatario de WhatsApp válido para esta empresa.",
      }, 409);
    }

    const { data: lastInbound, error: inboundError } = await adminClient.from(
      "whatsapp_messages",
    )
      .select("provider_timestamp,created_at").eq("tenant_id", tenantId)
      .eq("conversation_id", conversationId).eq("direction", "inbound").eq(
        "source",
        "cloud_api",
      )
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (inboundError) throw inboundError;
    const timestamp = lastInbound?.provider_timestamp ??
      lastInbound?.created_at;
    if (
      !timestamp || Date.now() - Date.parse(timestamp) >= 24 * 60 * 60 * 1000
    ) {
      return json({
        error:
          "La ventana de atención de 24 horas expiró. El cliente debe escribir nuevamente o recibir una plantilla aprobada.",
      }, 409);
    }
    const { error: pauseError } = await userClient.rpc("control_whatsapp_bot", {
      p_tenant_id: tenantId,
      p_conversation_id: conversationId,
      p_action: "pause",
    });
    if (pauseError) throw pauseError;
    const accessToken = await accountToken(
      adminClient,
      tenantId,
      phoneNumberId,
    );
    const graphResponse = await fetch(
      `https://graph.facebook.com/${graphVersion()}/${
        encodeURIComponent(phoneNumberId)
      }/messages`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + accessToken,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          ...messageRecipient(contact, conversation.whatsapp_account_id),
          type: "text",
          text: { preview_url: false, body: messageBody.trim() },
        }),
        signal: AbortSignal.timeout(15000),
      },
    );
    const graphData = await graphResponse.json();
    if (!graphResponse.ok) {
      console.error("Meta rejected WhatsApp message", graphData);
      return json({
        error: graphData.error?.message ?? "Meta rejected the message",
        error_code: graphData.error?.code ?? null,
      }, 400);
    }

    const providerMessageId = graphData.messages?.[0]?.id;
    if (typeof providerMessageId !== "string") {
      return json({ error: "Meta did not return a message identifier" }, 502);
    }

    const { error: insertError } = await adminClient
      .from("whatsapp_messages")
      .upsert({
        tenant_id: tenantId,
        conversation_id: conversation.id,
        whatsapp_account_id: conversation.whatsapp_account_id,
        provider_message_id: providerMessageId,
        direction: "outbound",
        message_type: "text",
        body: messageBody.trim(),
        delivery_status: "accepted",
      }, {
        onConflict: "whatsapp_account_id,provider_message_id",
        ignoreDuplicates: true,
      });
    if (insertError) throw insertError;

    const { error: updateError } = await adminClient
      .from("whatsapp_conversations")
      .update({
        last_message_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", conversation.id)
      .eq("tenant_id", tenantId);
    if (updateError) throw updateError;

    return json({ ok: true, provider_message_id: providerMessageId });
  } catch (error) {
    console.error("WhatsApp send error", error);
    if (error instanceof WhatsAppError) {
      return json({ error: error.message }, error.status);
    }
    return json({ error: "Unexpected WhatsApp sending error" }, 500);
  }
}

if (import.meta.main) Deno.serve(sendWhatsAppMessage);
