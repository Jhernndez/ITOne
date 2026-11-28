import { graph, json, requireTenantAdmin, WhatsAppError, corsHeaders } from "../_shared/whatsapp.ts";
import { platformMetaConfiguration } from "../_shared/platform_meta.ts";

async function readInput(request: Request): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw new WhatsAppError("Solicitud inválida");
  const decoder = new TextDecoder();
  let raw = "", size = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    size += part.value.length;
    if (size > 8192) {
      await reader.cancel();
      throw new WhatsAppError("Solicitud demasiado grande", 413);
    }
    raw += decoder.decode(part.value, { stream: true });
  }
  raw += decoder.decode();
  let input: unknown;
  try { input = JSON.parse(raw); } catch { throw new WhatsAppError("Solicitud inválida"); }
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new WhatsAppError("Solicitud inválida");
  }
  return input as Record<string, unknown>;
}

export async function connectWhatsAppCloud(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Método no permitido" }, 405);
  try {
    const input = await readInput(request);
    if (!input || typeof input.tenant_id !== "string" ||
        typeof input.waba_id !== "string" || !/^\d{1,40}$/.test(input.waba_id) ||
        typeof input.phone_number_id !== "string" || !/^\d{1,40}$/.test(input.phone_number_id) ||
        typeof input.access_token !== "string" || input.access_token.length < 1 ||
        input.access_token.length > 4096) {
      throw new WhatsAppError("Completa los identificadores y el token de Meta.");
    }
    const admin = await requireTenantAdmin(request, input.tenant_id);
    const config = await platformMetaConfiguration(admin);
    if (!config.appId || !config.appSecret) {
      throw new WhatsAppError("Falta la configuración de Meta de ITONE.", 503);
    }
    const token = input.access_token;
    let debug: { data: { is_valid: boolean; app_id: string } };
    try {
      debug = await graph(
        `debug_token?input_token=${encodeURIComponent(token)}`, `${config.appId}|${config.appSecret}`,
      );
    } catch {
      throw new WhatsAppError("Meta no pudo validar el token. Revisa sus permisos y vigencia.", 502);
    }
    if (!debug.data?.is_valid || debug.data.app_id !== config.appId) {
      throw new WhatsAppError("El token no pertenece a la aplicación Meta de ITONE.", 403);
    }
    let phones: { data: { id: string; display_phone_number?: string; verified_name?: string; is_on_biz_app?: boolean }[] };
    try {
      phones = await graph(
        `${input.waba_id}/phone_numbers?fields=id,display_phone_number,verified_name,is_on_biz_app&limit=100`, token,
      );
    } catch {
      throw new WhatsAppError("Meta no pudo consultar los números de la cuenta. Revisa el token y sus permisos.", 502);
    }
    const phone = phones.data?.find((item) => item.id === input.phone_number_id);
    if (!phone) throw new WhatsAppError("Meta no confirmó que el número pertenece a esa cuenta.", 403);
    if (phone.is_on_biz_app === true) {
      throw new WhatsAppError("Este número usa WhatsApp Business en el celular. Conéctalo mediante coexistencia.", 409);
    }
    const { error } = await admin.rpc("connect_whatsapp_cloud_number", {
      p_tenant: input.tenant_id,
      p_phone: phone.id,
      p_waba: input.waba_id,
      p_token: token,
      p_display: phone.display_phone_number ?? "",
      p_name: phone.verified_name ?? "WhatsApp Cloud API",
    });
    if (error) {
      console.error("No se pudo guardar el número de WhatsApp", { code: error.code });
      throw new WhatsAppError("No se pudo guardar el número. Revisa si ya pertenece a otra conexión.", 409);
    }
    try {
      const subscription = await graph<{ success?: boolean }>(
        `${input.waba_id}/subscribed_apps`, token, "POST", {},
      );
      if (subscription.success !== true) throw new Error("Meta no confirmó la suscripción");
    } catch {
      return json({
        ok: true,
        warning: "El número se guardó, pero Meta no confirmó la suscripción del webhook. Revisa la conexión antes de usarlo.",
      });
    }
    return json({ ok: true, message: "Número guardado. Meta debe autorizar los envíos y la entrega del webhook." });
  } catch (error) {
    if (error instanceof WhatsAppError) return json({ error: error.message }, error.status);
    console.error("No se pudo conectar WhatsApp Cloud");
    return json({ error: "No fue posible verificar la conexión con Meta." }, 500);
  }
}

if (import.meta.main) Deno.serve(connectWhatsAppCloud);
