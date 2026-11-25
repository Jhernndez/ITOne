import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { graphVersion, WhatsAppError } from "./whatsapp.ts";

export interface PlatformMetaConfiguration {
  appId: string | undefined;
  configId: string | undefined;
  appSecret: string | undefined;
  verifyToken: string | undefined;
  source: "platform" | "environment";
}
export async function platformMetaConfiguration(
  admin: SupabaseClient,
): Promise<PlatformMetaConfiguration> {
  const { data, error } = await admin.rpc("read_platform_meta_configuration");
  if (error) {
    console.error("Platform Meta configuration read failed", {
      code: error.code,
    });
    throw new WhatsAppError(
      "No se pudo leer la configuración de Meta del servidor.",
      503,
    );
  }
  return {
    appId: data?.app_id ?? Deno.env.get("META_APP_ID"),
    configId: data?.config_id ?? Deno.env.get("META_WHATSAPP_CONFIG_ID"),
    appSecret: data?.app_secret ?? Deno.env.get("META_APP_SECRET"),
    verifyToken: data?.verify_token ?? Deno.env.get("WHATSAPP_VERIFY_TOKEN"),
    source: data ? "platform" : "environment",
  };
}
export const coexistenceFields = [
  "messages",
  "smb_message_echoes",
  "smb_app_state_sync",
  "history",
];
async function appRequest(
  path: string,
  config: PlatformMetaConfiguration,
  body?: URLSearchParams,
) {
  if (!config.appId || !config.appSecret) {
    throw new WhatsAppError("Faltan App ID o App Secret de Meta", 409);
  }
  let response: Response;
  try {
    response = await fetch(
      `https://graph.facebook.com/${graphVersion()}/${path}`,
      {
        method: body ? "POST" : "GET",
        body,
        headers: {
          Authorization: `Bearer ${config.appId}|${config.appSecret}`,
        },
        signal: AbortSignal.timeout(15000),
      },
    );
  } catch {
    console.error("Meta application request unavailable");
    throw new WhatsAppError(
      "No se pudo contactar a Meta. Intenta de nuevo.",
      502,
    );
  }
  let data;
  try {
    data = await response.json();
  } catch {
    console.error("Meta application response invalid", {
      status: response.status,
    });
    throw new WhatsAppError("Meta devolvió una respuesta no válida.", 502);
  }
  if (!response.ok || data.error) {
    console.error("Meta app credential check rejected", {
      status: response.status,
      code: data.error?.code,
    });
    throw new WhatsAppError(
      `Meta no pudo validar la aplicación (código ${
        data.error?.code ?? response.status
      }). Revisa App ID y App Secret.`,
      400,
    );
  }
  return data;
}
export async function verifyMetaApp(config: PlatformMetaConfiguration) {
  const app = await appRequest(
    `${encodeURIComponent(config.appId ?? "")}?fields=id,name`,
    config,
  );
  if (app.id !== config.appId) {
    throw new WhatsAppError("Meta devolvió otra aplicación", 400);
  }
  return { id: app.id as string, name: app.name as string | undefined };
}
export async function checkMetaApp(config: PlatformMetaConfiguration) {
  const app = await verifyMetaApp(config);
  const subscriptions = await appRequest(
    `${encodeURIComponent(config.appId!)}/subscriptions`,
    config,
  );
  const expected = `${
    Deno.env.get("SUPABASE_URL")
  }/functions/v1/whatsapp-webhook`;
  const webhook = (Array.isArray(subscriptions.data) ? subscriptions.data : [])
    .find(
      (s: { object?: string }) => s.object === "whatsapp_business_account",
    );
  const fields: string[] = Array.isArray(webhook?.fields)
    ? webhook.fields.map((f: { name?: string }) => f.name).filter((
      name: unknown,
    ) => typeof name === "string")
    : [];
  return {
    app_id: app.id,
    app_name: app.name ?? null,
    app_credentials_valid: true,
    webhook_matches: webhook?.callback_url === expected,
    webhook_active: webhook?.active === true,
    webhook_fields: Array.isArray(webhook?.fields)
      ? webhook.fields.map((f: { name?: string }) => f.name).filter((
        name: unknown,
      ) => typeof name === "string")
      : [],
    coexistence_missing_fields: coexistenceFields.filter((field) =>
      !fields.includes(field)
    ),
    coexistence_webhooks_ready: webhook?.callback_url === expected &&
      webhook?.active === true &&
      coexistenceFields.every((field) => fields.includes(field)),
    config_id: config.configId ?? null,
    message:
      "Credenciales de la aplicación verificadas. El Config ID debe corresponder a Embedded Signup con coexistencia; esta prueba no autoriza ni registra números.",
  };
}

export async function configureCoexistenceWebhooks(
  config: PlatformMetaConfiguration,
) {
  const before = await checkMetaApp(config);
  if (!before.webhook_matches || !config.verifyToken) {
    throw new WhatsAppError(
      "Primero configura el webhook de ITONE y su token de verificación.",
      409,
    );
  }
  if (before.coexistence_webhooks_ready) return before;
  const fields = [...new Set([...before.webhook_fields, ...coexistenceFields])];
  const result = await appRequest(
    `${encodeURIComponent(config.appId!)}/subscriptions`,
    config,
    new URLSearchParams({
      object: "whatsapp_business_account",
      callback_url: `${
        Deno.env.get("SUPABASE_URL")
      }/functions/v1/whatsapp-webhook`,
      verify_token: config.verifyToken,
      fields: fields.join(","),
    }),
  );
  if (result.success !== true) {
    throw new WhatsAppError("Meta no confirmó las suscripciones.", 502);
  }
  const after = await checkMetaApp(config);
  if (!after.coexistence_webhooks_ready) {
    throw new WhatsAppError(
      "Meta aún no confirma todos los eventos de coexistencia. Revisa el panel de webhooks.",
      409,
    );
  }
  return after;
}
