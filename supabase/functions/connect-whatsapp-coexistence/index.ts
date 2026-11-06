import {
  graph, graphVersion, json, requireTenantAdmin, WhatsAppError, corsHeaders,
} from "../_shared/whatsapp.ts";

interface Phone {
  id: string;
  display_phone_number?: string;
  verified_name?: string;
  is_on_biz_app?: boolean;
  platform_type?: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const body = await request.json();
    if (typeof body.tenant_id !== "string") {
      throw new WhatsAppError("tenant_id is required");
    }
    const admin = await requireTenantAdmin(request, body.tenant_id);
    const appId = Deno.env.get("META_APP_ID");
    const appSecret = Deno.env.get("META_APP_SECRET");
    const configId = Deno.env.get("META_WHATSAPP_CONFIG_ID");
    if (!appId || !appSecret || !configId) {
      throw new WhatsAppError(
        "Falta configurar META_APP_ID, META_APP_SECRET y META_WHATSAPP_CONFIG_ID en Supabase.",
        503,
      );
    }
    if (body.action === "configuration") {
      return json({ app_id: appId, config_id: configId, graph_version: graphVersion() });
    }
    if (typeof body.code !== "string" || !body.code ||
        typeof body.waba_id !== "string" || !/^\d+$/.test(body.waba_id) ||
        body.event !== "FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING") {
      throw new WhatsAppError("Debes completar el flujo de WhatsApp Business con coexistencia.");
    }
    // Never trust browser asset IDs alone: verify the exchanged token's app and
    // the number's membership in the granted WABA before assigning a tenant.
    const tokenParameters = new URLSearchParams({
      client_id: appId, client_secret: appSecret, code: body.code,
    });
    const tokenResponse = await fetch(
      `https://graph.facebook.com/${graphVersion()}/oauth/access_token?${tokenParameters}`,
    );
    const tokenData: { access_token?: string; error?: { message?: string } } = await tokenResponse.json();
    if (!tokenResponse.ok || !tokenData.access_token) {
      throw new WhatsAppError(tokenData.error?.message ?? "Meta no devolvió credenciales. Repite la conexión.");
    }
    const token = tokenData.access_token;
    const debug = await graph<{ data: { is_valid: boolean; app_id: string } }>(
      `debug_token?input_token=${encodeURIComponent(token)}`, `${appId}|${appSecret}`,
    );
    if (!debug.data.is_valid || debug.data.app_id !== appId) {
      throw new WhatsAppError("Meta devolvió un token inválido para esta aplicación.", 403);
    }
    const phones = await graph<{ data: Phone[] }>(
      `${body.waba_id}/phone_numbers?fields=id,display_phone_number,verified_name,is_on_biz_app,platform_type&limit=100`,
      token,
    );
    const candidates = phones.data.filter((phone) =>
      phone.is_on_biz_app === true && phone.platform_type === "CLOUD_API" &&
      (!body.phone_number_id || phone.id === body.phone_number_id)
    );
    if (candidates.length !== 1) {
      throw new WhatsAppError(
        "Meta no confirmó un único número con coexistencia. Usa WhatsApp Business y conecta el número existente.",
        409,
      );
    }
    const phone = candidates[0];
    const { data: existing, error: existingError } = await admin.from("whatsapp_accounts")
      .select("tenant_id").or(`phone_number_id.eq.${phone.id},business_account_id.eq.${body.waba_id}`);
    if (existingError) throw existingError;
    if (existing?.some((account) => account.tenant_id !== body.tenant_id)) {
      throw new WhatsAppError("Esta cuenta de WhatsApp pertenece a otra empresa de la plataforma.", 409);
    }
    const subscription = await graph<{ success?: boolean }>(
      `${body.waba_id}/subscribed_apps`, token, "POST", {},
    );
    if (subscription.success !== true) {
      throw new WhatsAppError("Meta no confirmó la suscripción del webhook.", 502);
    }
    const { data: accountId, error: connectError } = await admin.rpc("connect_whatsapp_coexistence", {
      p_tenant_id: body.tenant_id,
      p_phone_number_id: phone.id,
      p_business_account_id: body.waba_id,
      p_access_token: token,
      p_display_phone_number: phone.display_phone_number ?? "",
      p_name: phone.verified_name ?? "WhatsApp Business",
    });
    if (connectError) throw connectError;

    // Claim before requesting: Meta permits each sync request only once.
    const { data: claimed, error: claimError } = await admin.from("whatsapp_accounts")
      .update({ history_sync_status: "pending", history_sync_error: null })
      .eq("id", accountId).eq("history_sync_status", "not_requested")
      .select("id").maybeSingle();
    if (claimError) throw claimError;
    if (claimed) {
      try {
        const contacts = await graph<{ request_id?: string }>(
          `${phone.id}/smb_app_data`, token, "POST",
          { messaging_product: "whatsapp", sync_type: "smb_app_state_sync" },
        );
        if (!contacts.request_id) throw new WhatsAppError("Meta no confirmó la sincronización de contactos.", 502);
        const { error } = await admin.from("whatsapp_accounts")
          .update({ contacts_sync_request_id: contacts.request_id }).eq("id", accountId);
        if (error) throw error;
        const history = await graph<{ request_id?: string }>(
          `${phone.id}/smb_app_data`, token, "POST",
          { messaging_product: "whatsapp", sync_type: "history" },
        );
        if (!history.request_id) throw new WhatsAppError("Meta no confirmó la solicitud de historial.", 502);
        const { error: historyError } = await admin.from("whatsapp_accounts")
          .update({ history_sync_request_id: history.request_id }).eq("id", accountId);
        if (historyError) throw historyError;
      } catch (error) {
        console.error("WhatsApp initial sync failed", { accountId, error });
        const message = error instanceof WhatsAppError ? error.message : "Error guardando la solicitud de sincronización.";
        const { error: saveError } = await admin.from("whatsapp_accounts")
          .update({ history_sync_status: "error", history_sync_error: message })
          .eq("id", accountId).in("history_sync_status", ["pending", "syncing"]);
        if (saveError) throw saveError;
        return json({
          ok: true, sync_warning: message,
          message: "Coexistencia conectada, pero la solicitud de sincronización falló. Revisa el estado antes de volver a conectar.",
        });
      }
    }
    return json({
      ok: true,
      message: "Coexistencia verificada. El historial autorizado llegará por webhook; la conexión no garantiza que Meta permita enviar.",
    });
  } catch (error) {
    console.error("WhatsApp coexistence connection failed", error instanceof Error ? error.message : "Unknown error");
    return json({
      error: error instanceof WhatsAppError ? error.message : "No fue posible guardar la conexión de WhatsApp.",
    }, error instanceof WhatsAppError ? error.status : 500);
  }
});
