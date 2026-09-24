import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
  return role === "tenant_admin" || role === "supervisor" || role === "operator";
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
  if (!supabaseUrl || !serviceRoleKey || !accessToken) {
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
    if (userError || !user) return json({ error: "Authentication required" }, 401);

    const body = await request.json();
    const tenantId = body?.tenant_id;
    const conversationId = body?.conversation_id;
    const messageBody = body?.message;
    if (
      typeof tenantId !== "string" ||
      typeof conversationId !== "string" ||
      typeof messageBody !== "string" ||
      !messageBody.trim()
    ) {
      return json({
        error: "tenant_id, conversation_id and message are required",
      }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data: membership } = await adminClient
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenantId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!isAllowedRole(membership?.role)) {
      return json({ error: "You are not allowed to send WhatsApp messages" }, 403);
    }

    const { data: conversation, error: conversationError } = await adminClient
      .from("whatsapp_conversations")
      .select(
        "id, tenant_id, whatsapp_account_id, contact_id, whatsapp_accounts(phone_number_id, status), whatsapp_contacts(phone_number)",
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
    const recipient = contact?.phone_number;
    if (
      account?.status !== "active" ||
      typeof phoneNumberId !== "string" ||
      typeof recipient !== "string"
    ) {
      return json({ error: "WhatsApp account or recipient is not configured" }, 400);
    }

    const graphResponse = await fetch(
      `https://graph.facebook.com/v23.0/${encodeURIComponent(phoneNumberId)}/messages`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + accessToken,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: recipient,
          type: "text",
          text: { preview_url: false, body: messageBody.trim() },
        }),
      },
    );
    const graphData = await graphResponse.json();
    if (!graphResponse.ok) {
      console.error("Meta rejected WhatsApp message", graphData);
      return json({
        error: graphData.error?.message ?? "Meta rejected the message",
      }, 400);
    }

    const providerMessageId = graphData.messages?.[0]?.id;
    if (typeof providerMessageId !== "string") {
      return json({ error: "Meta did not return a message identifier" }, 502);
    }

    const { error: insertError } = await adminClient
      .from("whatsapp_messages")
      .insert({
        tenant_id: tenantId,
        conversation_id: conversation.id,
        whatsapp_account_id: conversation.whatsapp_account_id,
        provider_message_id: providerMessageId,
        direction: "outbound",
        message_type: "text",
        body: messageBody.trim(),
        delivery_status: "sent",
      });
    if (insertError) throw insertError;

    await adminClient
      .from("whatsapp_conversations")
      .update({
        last_message_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", conversation.id)
      .eq("tenant_id", tenantId);

    return json({ ok: true, provider_message_id: providerMessageId });
  } catch (error) {
    console.error("WhatsApp send error", error);
    return json({ error: "Unexpected WhatsApp sending error" }, 500);
  }
});
