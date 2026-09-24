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

// Registers a WhatsApp business phone number for use with the Cloud API.
// This is a one-time step required by Meta in addition to connecting the
// number in WhatsApp Manager: POST /PHONE_NUMBER_ID/register with a 6-digit
// two-step verification PIN. Without this, message sends can fail with
// misleading errors such as 131031 "Business Account locked".
Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
  if (!supabaseUrl || !serviceRoleKey || !accessToken) {
    return json({ error: "WhatsApp registration secrets are not configured" }, 500);
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
    const pin = body?.pin;
    if (typeof tenantId !== "string") return json({ error: "tenant_id is required" }, 400);
    if (typeof pin !== "string" || !/^\d{6}$/.test(pin)) {
      return json({ error: "pin must be a 6-digit string" }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const { data: membership } = await adminClient
      .from("tenant_memberships")
      .select("role")
      .eq("tenant_id", tenantId)
      .eq("user_id", user.id)
      .maybeSingle();
    const { data: platformMembership } = await adminClient
      .from("platform_memberships")
      .select("role")
      .eq("user_id", user.id)
      .maybeSingle();
    const canRegister =
      membership?.role === "tenant_admin" ||
      platformMembership?.role === "platform_owner" ||
      platformMembership?.role === "platform_admin";
    if (!canRegister) {
      return json({ error: "Only tenant or platform administrators can register WhatsApp numbers" }, 403);
    }

    const { data: integration, error: integrationError } = await adminClient
      .from("tenant_integrations")
      .select("id, metadata")
      .eq("tenant_id", tenantId)
      .eq("provider", "whatsapp")
      .maybeSingle();
    if (integrationError) throw integrationError;
    const metadata = integration?.metadata ?? {};
    const phoneNumberId = metadata.phone_number_id;
    if (!integration || typeof phoneNumberId !== "string" || !phoneNumberId) {
      return json({ error: "WhatsApp integration is not configured" }, 400);
    }

    const graphResponse = await fetch(
      `https://graph.facebook.com/v23.0/${encodeURIComponent(phoneNumberId)}/register`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + accessToken,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ messaging_product: "whatsapp", pin }),
      },
    );
    const graphData = await graphResponse.json();
    if (!graphResponse.ok) {
      console.error("Meta rejected phone number registration", graphData);
      return json({
        error: graphData.error?.message ?? "Meta rejected the registration request",
        details: graphData.error ?? null,
      }, 400);
    }

    await adminClient.from("tenant_integrations").update({
      metadata: { ...metadata, registered_at: new Date().toISOString() },
      updated_at: new Date().toISOString(),
    }).eq("id", integration.id);

    return json({ ok: true, success: graphData.success ?? true });
  } catch (error) {
    console.error("WhatsApp phone registration error", error);
    return json({ error: "Unexpected registration error" }, 500);
  }
});
