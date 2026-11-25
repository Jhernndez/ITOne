import { requirePlatformOwner } from "../_shared/platform_owner.ts";
import {
  corsHeaders,
  graphVersion,
  json,
  WhatsAppError,
} from "../_shared/whatsapp.ts";

export async function platformWhatsAppSettings(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  try {
    const admin = await requirePlatformOwner(request);
    let body;
    try {
      body = await request.json();
    } catch {
      throw new WhatsAppError("JSON no válido.");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new WhatsAppError("Solicitud no válida.");
    }
    if (body.action === "configuration") {
      return json({
        app_id: Deno.env.get("META_APP_ID") ?? null,
        config_id: Deno.env.get("META_WHATSAPP_CONFIG_ID") ?? null,
        graph_version: graphVersion(),
        app_secret_configured: Boolean(Deno.env.get("META_APP_SECRET")),
        webhook_verify_token_configured: Boolean(
          Deno.env.get("WHATSAPP_VERIFY_TOKEN"),
        ),
        bot_worker_configured: Boolean(Deno.env.get("WHATSAPP_BOT_WORKER_SECRET")),
        webhook_url: `${
          Deno.env.get("SUPABASE_URL")
        }/functions/v1/whatsapp-webhook`,
      });
    }
    if (body.action === "tenants") {
      const { data, error } = await admin.from("tenants").select("id,name")
        .order("name");
      if (error) throw error;
      return json({ tenants: data });
    }
    if (
      body.action !== "diagnostics" ||
      typeof body.tenant_id !== "string" ||
      !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.tenant_id)
    ) {
      throw new WhatsAppError("Solicitud no válida.");
    }
    const { data: integration, error: integrationError } = await admin
      .from("tenant_integrations").select("status,metadata")
      .eq("tenant_id", body.tenant_id).eq("provider", "whatsapp").maybeSingle();
    if (integrationError) throw integrationError;
    const { data: accounts, error: accountsError } = await admin
      .from("whatsapp_accounts")
      .select(
        "id,name,business_account_id,phone_number_id,display_phone_number,status,onboarding_mode",
      )
      .eq("tenant_id", body.tenant_id).order("created_at");
    if (accountsError) throw accountsError;
    const metadata = integration?.metadata ?? {};
    return json({
      integration: integration
        ? {
          status: integration.status,
          business_account_id: metadata.business_account_id ?? null,
          phone_number_id: metadata.phone_number_id ?? null,
          onboarding_mode: metadata.onboarding_mode ?? "cloud_api",
        }
        : null,
      accounts,
    });
  } catch (error) {
    console.error("Platform WhatsApp settings failed", {
      status: error instanceof WhatsAppError ? error.status : 500,
    });
    return json({
      error: error instanceof WhatsAppError
        ? error.message
        : "No se pudo consultar la configuración interna.",
    }, error instanceof WhatsAppError ? error.status : 500);
  }
}

if (import.meta.main) Deno.serve(platformWhatsAppSettings);
