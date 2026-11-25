import { requirePlatformOwner } from "../_shared/platform_owner.ts";
import {
  checkMetaApp,
  configureCoexistenceWebhooks,
  platformMetaConfiguration,
  verifyMetaApp,
} from "../_shared/platform_meta.ts";
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
    let body: Record<string, unknown>;
    try {
      const reader = request.body?.getReader();
      if (!reader) throw new WhatsAppError("JSON no válido.");
      const decoder = new TextDecoder();
      let text = "", bytes = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          bytes += value.byteLength;
          if (bytes > 8192) {
            await reader.cancel();
            throw new WhatsAppError("La solicitud es demasiado grande.", 413);
          }
          text += decoder.decode(value, { stream: true });
        }
        text += decoder.decode();
      } finally {
        reader.releaseLock();
      }
      const parsed: unknown = JSON.parse(text);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new WhatsAppError("Solicitud no válida.");
      }
      body = parsed as Record<string, unknown>;
    } catch (error) {
      if (error instanceof WhatsAppError) throw error;
      throw new WhatsAppError("JSON no válido.");
    }
    if (body.action === "configuration") {
      const config = await platformMetaConfiguration(admin);
      return json({
        app_id: config.appId ?? null,
        config_id: config.configId ?? null,
        configuration_source: config.source,
        graph_version: graphVersion(),
        app_secret_configured: Boolean(config.appSecret),
        webhook_verify_token_configured: Boolean(
          config.verifyToken,
        ),
        bot_worker_configured: Boolean(
          Deno.env.get("WHATSAPP_BOT_WORKER_SECRET"),
        ),
        webhook_url: `${
          Deno.env.get("SUPABASE_URL")
        }/functions/v1/whatsapp-webhook`,
      });
    }
    if (body.action === "check_app") {
      return json(await checkMetaApp(await platformMetaConfiguration(admin)));
    }
    if (body.action === "configure_coexistence_webhooks") {
      return json(
        await configureCoexistenceWebhooks(
          await platformMetaConfiguration(admin),
        ),
      );
    }
    if (body.action === "save_configuration") {
      if (
        typeof body.app_id !== "string" || !/^\d{5,30}$/.test(body.app_id) ||
        typeof body.config_id !== "string" || !/^\d{5,30}$/.test(body.config_id)
      ) {
        throw new WhatsAppError(
          "App ID y Config ID deben ser identificadores numéricos de Meta.",
        );
      }
      for (const name of ["app_secret", "verify_token"]) {
        const value = body[name];
        if (
          value !== undefined &&
          (typeof value !== "string" || value.length > 256)
        ) {
          throw new WhatsAppError("Secretos no válidos.");
        }
      }
      const newSecret = typeof body.app_secret === "string"
        ? body.app_secret.trim()
        : "";
      const newVerifyToken = typeof body.verify_token === "string"
        ? body.verify_token.trim()
        : "";
      const current = await platformMetaConfiguration(admin);
      if (current.appId !== body.app_id && !newSecret) {
        throw new WhatsAppError(
          "Al cambiar la aplicación debes ingresar su App Secret.",
        );
      }
      const appSecret = newSecret || current.appSecret;
      if (
        (newSecret && newSecret.length < 16) ||
        (newVerifyToken && newVerifyToken.length < 8)
      ) {
        throw new WhatsAppError("El secreto o token es demasiado corto.");
      }
      await verifyMetaApp({ ...current, appId: body.app_id, appSecret });
      const { error } = await admin.rpc("write_platform_meta_configuration", {
        p_app_id: body.app_id,
        p_config_id: body.config_id,
        p_app_secret: newSecret || null,
        p_verify_token: newVerifyToken || null,
      });
      if (error) {
        console.error("Meta settings save failed", { code: error.code });
        throw new WhatsAppError(
          "No se pudo guardar la configuración de Meta.",
          500,
        );
      }
      return json({
        ok: true,
        message:
          "Configuración guardada. Los secretos no se muestran y los campos vacíos conservan el valor anterior.",
      });
    }
    if (body.action === "tenants") {
      const { data, error } = await admin.from("tenants").select("id,name")
        .order("name");
      if (error) {
        console.error("Platform company list failed", { code: error.code });
        throw new WhatsAppError(
          "No se pudo listar las empresas. Revisa el permiso de lectura del servidor en Supabase.",
          503,
        );
      }
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
