import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  accountToken,
  corsHeaders,
  graphVersion,
  json,
  WhatsAppError,
} from "../_shared/whatsapp.ts";

const maxBytes = 5 * 1024 * 1024;
const imageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

export async function messageImage(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  try {
    const auth = request.headers.get("Authorization");
    if (!auth) throw new WhatsAppError("Authentication required", 401);
    const url = Deno.env.get("SUPABASE_URL"),
      key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) throw new WhatsAppError("Servidor no configurado.", 503);
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user) {
      throw new WhatsAppError("Authentication required", 401);
    }
    const { data: disabled, error: disabledError } = await caller.rpc(
      "is_current_user_disabled",
    );
    if (disabledError) throw disabledError;
    if (disabled) throw new WhatsAppError("User access is disabled", 403);
    const input = request.body?.getReader();
    if (!input) throw new WhatsAppError("Solicitud vacía.");
    let raw = "", inputSize = 0;
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { value, done } = await input.read();
        if (done) break;
        inputSize += value.length;
        if (inputSize > 2048) {
          await input.cancel();
          throw new WhatsAppError("Solicitud demasiado grande.", 413);
        }
        raw += decoder.decode(value, { stream: true });
      }
      raw += decoder.decode();
    } finally {
      input.releaseLock();
    }
    let body;
    try {
      body = JSON.parse(raw);
    } catch {
      throw new WhatsAppError("JSON no válido.");
    }
    if (
      typeof body?.tenant_id !== "string" ||
      typeof body?.message_id !== "string"
    ) {
      throw new WhatsAppError("Empresa y mensaje son obligatorios.");
    }
    const { data: role, error: roleError } = await caller.rpc(
      "current_tenant_role",
      { p_tenant_id: body.tenant_id },
    );
    if (roleError) throw roleError;
    if (!["tenant_admin", "supervisor", "operator"].includes(role)) {
      throw new WhatsAppError("No tienes permiso para ver esta imagen.", 403);
    }
    const admin = createClient(url, key);
    const { data: message, error } = await admin.from("whatsapp_messages")
      .select("media_id,message_type,whatsapp_account_id").eq(
        "id",
        body.message_id,
      ).eq("tenant_id", body.tenant_id).maybeSingle();
    if (error) throw error;
    if (!message) throw new WhatsAppError("Mensaje no encontrado.", 404);
    const { data: permitted, error: accessError } = await caller.rpc(
      "can_access_whatsapp_number",
      { p_tenant_id: body.tenant_id, p_account_id: message.whatsapp_account_id },
    );
    if (accessError) throw accessError;
    if (!permitted) throw new WhatsAppError("No tienes acceso a este número.", 403);
    if (
      !message.media_id || !["image", "sticker"].includes(message.message_type)
    ) {
      throw new WhatsAppError(
        "Esta imagen no está disponible. Meta puede no incluir archivos en el historial.",
        409,
      );
    }
    const { data: account, error: accountError } = await admin.from(
      "whatsapp_accounts",
    )
      .select("phone_number_id,status").eq("id", message.whatsapp_account_id)
      .eq("tenant_id", body.tenant_id).maybeSingle();
    if (accountError) throw accountError;
    if (!account || account.status !== "active") {
      throw new WhatsAppError("La conexión de WhatsApp no está activa.", 409);
    }
    const token = await accountToken(
      admin,
      body.tenant_id,
      account.phone_number_id,
    );
    const metadataResponse = await fetch(
      `https://graph.facebook.com/${graphVersion()}/${
        encodeURIComponent(message.media_id)
      }?phone_number_id=${encodeURIComponent(account.phone_number_id)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(15000),
      },
    );
    const metadata = await metadataResponse.json();
    if (!metadataResponse.ok || metadata.error) {
      console.error("WhatsApp image metadata rejected", {
        status: metadataResponse.status,
        code: metadata.error?.code,
      });
      throw new WhatsAppError(
        "Meta no permite descargar esta imagen o el archivo expiró.",
        502,
      );
    }
    if (
      typeof metadata.url !== "string" || !imageTypes.has(metadata.mime_type) ||
      !Number.isFinite(Number(metadata.file_size)) ||
      Number(metadata.file_size) > maxBytes
    ) {
      throw new WhatsAppError("Formato o tamaño de imagen no admitido.", 413);
    }
    const mediaUrl = new URL(metadata.url);
    if (
      mediaUrl.protocol !== "https:" || mediaUrl.port || mediaUrl.username ||
      mediaUrl.password ||
      !(mediaUrl.hostname.endsWith(".fbsbx.com") ||
        mediaUrl.hostname.endsWith(".fbcdn.net"))
    ) {
      throw new WhatsAppError(
        "Meta devolvió una ubicación de imagen no admitida.",
        502,
      );
    }
    const response = await fetch(mediaUrl, {
      headers: { Authorization: `Bearer ${token}` },
      redirect: "error",
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok || !response.body) {
      throw new WhatsAppError("No se pudo descargar la imagen de Meta.", 502);
    }
    const mime = response.headers.get("content-type")?.split(";")[0];
    if (!mime || !imageTypes.has(mime)) {
      await response.body.cancel();
      throw new WhatsAppError(
        "El archivo recibido no es una imagen admitida.",
        502,
      );
    }
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > maxBytes) {
          await reader.cancel();
          throw new WhatsAppError("La imagen supera el límite de 5 MB.", 413);
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(size);
    if (!size) throw new WhatsAppError("Meta devolvió una imagen vacía.", 502);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    let binary = "";
    for (let i = 0; i < bytes.length; i += 8192) {
      binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
    }
    return new Response(
      JSON.stringify({ mime_type: mime, base64: btoa(binary) }),
      {
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        },
      },
    );
  } catch (error) {
    console.error("WhatsApp image download failed", {
      status: error instanceof WhatsAppError ? error.status : 502,
    });
    return json({
      error: error instanceof WhatsAppError
        ? error.message
        : "No se pudo cargar la imagen. Intenta de nuevo.",
    }, error instanceof WhatsAppError ? error.status : 502);
  }
}
if (import.meta.main) Deno.serve(messageImage);
