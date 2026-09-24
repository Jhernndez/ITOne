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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN");
  if (!supabaseUrl || !serviceRoleKey || !accessToken) {
    return json({ error: "WhatsApp validation secrets are not configured" }, 500);
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
    if (typeof tenantId !== "string") return json({ error: "tenant_id is required" }, 400);

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
    const canValidate =
      membership?.role === "tenant_admin" ||
      platformMembership?.role === "platform_owner" ||
      platformMembership?.role === "platform_admin";
    if (!canValidate) {
      return json({ error: "Only tenant or platform administrators can validate WhatsApp" }, 403);
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
      `https://graph.facebook.com/v23.0/${encodeURIComponent(phoneNumberId)}?fields=id,display_phone_number,verified_name`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    const graphData = await graphResponse.json();
    if (!graphResponse.ok) {
      await adminClient.from("tenant_integrations").update({
        status: "error",
        updated_at: new Date().toISOString(),
      }).eq("id", integration.id);
      return json({ status: "error", error: graphData.error?.message ?? "Meta rejected the token" }, 400);
    }

    const safeMetadata = {
      ...metadata,
      verified_phone_number_id: graphData.id ?? phoneNumberId,
      verified_display_phone_number: graphData.display_phone_number ?? null,
      verified_name: graphData.verified_name ?? null,
    };
    await adminClient.from("tenant_integrations").update({
      status: "active",
      configured_at: new Date().toISOString(),
      metadata: safeMetadata,
      updated_at: new Date().toISOString(),
    }).eq("id", integration.id);

    return json({
      status: "active",
      message: "Conexión con Meta validada correctamente.",
      verified_name: graphData.verified_name ?? null,
    });
  } catch (error) {
    console.error("WhatsApp integration validation error", error);
    return json({ error: "Unexpected validation error" }, 500);
  }
});
