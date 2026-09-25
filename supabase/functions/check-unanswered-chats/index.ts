import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return new Response("Supabase secrets are not configured", { status: 500 });
  }

  try {
    const client = createClient(url, serviceKey);
    const { data: conversations, error: conversationsError } = await client
      .from("whatsapp_conversations")
      .select("id, tenant_id, contact_id, last_message_at")
      .eq("status", "open")
      .not("last_message_at", "is", null);
    if (conversationsError) throw conversationsError;

    let created = 0;
    for (const conversation of conversations ?? []) {
      const { data: latestMessages, error: messagesError } = await client
        .from("whatsapp_messages")
        .select("direction, body, created_at")
        .eq("conversation_id", conversation.id)
        .order("created_at", { ascending: false })
        .limit(1);
      if (messagesError) throw messagesError;
      const latest = latestMessages?.[0];
      if (!latest || latest.direction !== "inbound") continue;

      const { data: settings, error: settingsError } = await client
        .from("tenant_notification_settings")
        .select("user_id, unanswered_chat_threshold_minutes")
        .eq("tenant_id", conversation.tenant_id);
      if (settingsError) throw settingsError;
      if (!settings?.length) continue;

      const ageMinutes = (Date.now() - new Date(latest.created_at).getTime()) / 60000;
      const recipients = settings.filter(
        (setting) => ageMinutes >= setting.unanswered_chat_threshold_minutes,
      );
      if (!recipients.length) continue;

      const { data: existing, error: existingError } = await client
        .from("notifications")
        .select("recipient_user_id")
        .eq("tenant_id", conversation.tenant_id)
        .eq("type", "unanswered_chat")
        .contains("data", { conversation_id: conversation.id });
      if (existingError) throw existingError;
      const notified = new Set((existing ?? []).map((row) => row.recipient_user_id));
      const rows = recipients
        .filter((recipient) => !notified.has(recipient.user_id))
        .map((recipient) => ({
          tenant_id: conversation.tenant_id,
          recipient_user_id: recipient.user_id,
          type: "unanswered_chat",
          title: "Chat sin respuesta",
          body: `Hay un mensaje pendiente desde hace ${Math.floor(ageMinutes)} minutos.`,
          data: {
            conversation_id: conversation.id,
            last_message_at: latest.created_at,
            threshold_minutes: recipient.unanswered_chat_threshold_minutes,
          },
        }));
      if (!rows.length) continue;
      const { error: insertError } = await client.from("notifications").insert(rows);
      if (insertError) throw insertError;
      created += rows.length;
    }

    return new Response(JSON.stringify({ ok: true, created }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("Unanswered chat check failed", error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
