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
      `https://graph.facebook.com/v23.0/${encodeURIComponent(phoneNumberId)}?fields=id,display_phone_number,verified_name,health_status,quality_rating,messaging_limit_tier,name_status,code_verification_status,status,account_mode`,
      { headers: { "Authorization": "Bearer " + accessToken } },
    );
    const graphData = await graphResponse.json();
    if (!graphResponse.ok) {
      await adminClient.from("tenant_integrations").update({
        status: "error",
        updated_at: new Date().toISOString(),
      }).eq("id", integration.id);
      return json({ status: "error", error: graphData.error?.message ?? "Meta rejected the token" }, 400);
    }

    const healthEntities = Array.isArray(graphData.health_status?.entities)
      ? graphData.health_status.entities
      : [];
    // Only flag entities whose `can_send_message` (text messaging) status is not
    // AVAILABLE. The `can_receive_call_sip` status and its `errors` refer to the
    // separate WhatsApp Calling/SIP feature and must not be treated as a
    // messaging blocker, even if they appear on the same entity object.
    const blockedEntities = healthEntities
      .filter(
        (entity: { can_send_message?: string }) =>
          entity.can_send_message && entity.can_send_message !== "AVAILABLE",
      )
      .map((
        entity: {
          entity_type?: string;
          id?: string;
          can_send_message?: string;
          additional_info?: string[];
          errors?: unknown[];
        },
      ) => ({
        entity_type: entity.entity_type,
        id: entity.id,
        can_send_message: entity.can_send_message,
        // Real reason messaging is LIMITED/BLOCKED for this entity.
        additional_info: entity.additional_info ?? null,
        // Only surface `errors` when the messaging status itself is BLOCKED;
        // otherwise these errors belong to an unrelated capability (e.g. calling/SIP).
        messaging_errors: entity.can_send_message === "BLOCKED" ? entity.errors ?? null : null,
      }));

    // The phone number's own `status` field can also signal a restriction
    // (VERIFIED is healthy; RESTRICTED/FLAGGED/DISABLED mean Meta blocked it),
    // independent of what health_status.entities reports.
    const restrictedPhoneStatuses = ["RESTRICTED", "FLAGGED", "DISABLED"];
    const isPhoneRestricted = restrictedPhoneStatuses.includes(graphData.status);
    const isRestricted = blockedEntities.length > 0 || isPhoneRestricted;

    const safeMetadata = {
      ...metadata,
      verified_phone_number_id: graphData.id ?? phoneNumberId,
      verified_display_phone_number: graphData.display_phone_number ?? null,
      verified_name: graphData.verified_name ?? null,
      health_status: graphData.health_status ?? null,
      quality_rating: graphData.quality_rating ?? null,
      messaging_limit_tier: graphData.messaging_limit_tier ?? null,
      name_status: graphData.name_status ?? null,
      code_verification_status: graphData.code_verification_status ?? null,
      phone_status: graphData.status ?? null,
      account_mode: graphData.account_mode ?? null,
    };
    await adminClient.from("tenant_integrations").update({
      status: isRestricted ? "restricted" : "active",
      configured_at: new Date().toISOString(),
      metadata: safeMetadata,
      updated_at: new Date().toISOString(),
    }).eq("id", integration.id);

    return json({
      status: isRestricted ? "restricted" : "active",
      message: isRestricted
        ? "Meta reporta restricciones activas sobre esta integración."
        : "Conexión con Meta validada correctamente.",
      verified_name: graphData.verified_name ?? null,
      health_status: graphData.health_status ?? null,
      quality_rating: graphData.quality_rating ?? null,
      messaging_limit_tier: graphData.messaging_limit_tier ?? null,
      name_status: graphData.name_status ?? null,
      code_verification_status: graphData.code_verification_status ?? null,
      phone_status: graphData.status ?? null,
      account_mode: graphData.account_mode ?? null,
      blocked_entities: blockedEntities,
    });
  } catch (error) {
    console.error("WhatsApp integration validation error", error);
    return json({ error: "Unexpected validation error" }, 500);
  }
});
