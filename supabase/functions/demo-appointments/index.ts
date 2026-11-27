import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { json, requireTenantAdmin, WhatsAppError } from "../_shared/whatsapp.ts";

async function body(request: Request): Promise<Record<string, unknown>> {
  const length = request.headers.get("content-length");
  if (length && Number(length) > 4096) throw new WhatsAppError("Solicitud demasiado grande", 413);
  const reader = request.body?.getReader();
  if (!reader) throw new WhatsAppError("Solicitud inválida");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    size += part.value.length;
    if (size > 4096) {
      await reader.cancel();
      throw new WhatsAppError("Solicitud demasiado grande", 413);
    }
    chunks.push(part.value);
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; }
  let result: unknown;
  try { result = JSON.parse(new TextDecoder().decode(all)); }
  catch { throw new WhatsAppError("JSON inválido"); }
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new WhatsAppError("Solicitud inválida");
  }
  return result as Record<string, unknown>;
}

export async function demoAppointments(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-demo-key, idempotency-key",
    } });
  }
  if (request.method !== "POST" && request.method !== "GET") return json({error: "Método no permitido"}, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) throw new WhatsAppError("Demostración no configurada", 503);
    const action = new URL(request.url).pathname.split("/").filter(Boolean).at(-1);
    const input = request.method === "GET" ? {} : await body(request);
    if (action === "instalar") {
      if (request.method !== "POST") throw new WhatsAppError("Método no permitido", 405);
      if (typeof input.tenant_id !== "string") throw new WhatsAppError("Empresa requerida");
      const admin = await requireTenantAdmin(request, input.tenant_id);
      const key = Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");
      const {data, error} = await admin.rpc("install_demo_appointments", {
        p_tenant: input.tenant_id, p_base_url: `${url}/functions/v1/demo-appointments`, p_key: key,
      });
      if (error) {
        if (error.message.includes("ya esta instalada")) throw new WhatsAppError("La demostración ya está instalada", 409);
        console.error("No se pudo instalar la demostración", {code: error.code});
        throw new WhatsAppError("No se pudo instalar la demostración", 500);
      }
      return json({ok: true, ...data});
    }
    if (action !== "buscar" && action !== "reservar" && !(action === "demo-appointments" && request.method === "GET")) {
      throw new WhatsAppError("Operación no disponible", 404);
    }
    if ((action === "buscar" || action === "reservar") && request.method !== "POST") {
      throw new WhatsAppError("Método no permitido", 405);
    }
    const key = request.headers.get("x-demo-key");
    if (!key || !/^[a-f0-9]{64}$/.test(key)) throw new WhatsAppError("Credencial no válida", 401);
    const admin = createClient(url, serviceKey);
    const {data, error} = await admin.rpc("run_demo_appointments", {
      p_key: key, p_action: action === "demo-appointments" ? "salud" : action, p_body: input,
      p_idempotency_key: action === "reservar"
        ? request.headers.get("idempotency-key") ?? crypto.randomUUID()
        : null,
    });
    if (error) {
      if (error.message.includes("Credencial no valida")) throw new WhatsAppError("Credencial no válida", 401);
      if (error.message.includes("Horario no valido") || error.message.includes("clave de idempotencia")) {
        throw new WhatsAppError("Solicitud de cita ficticia inválida", 400);
      }
      if (error.message.includes("Clave de idempotencia ya utilizada")) {
        throw new WhatsAppError("La operación ya fue utilizada con otros datos", 409);
      }
      console.error("No se pudo ejecutar la demostración", {code: error.code});
      throw new WhatsAppError("No se pudo ejecutar la demostración", 500);
    }
    return json(data.body, data.status);
  } catch (error) {
    if (error instanceof WhatsAppError) return json({error: error.message}, error.status);
    console.error("Error en API de citas de demostración");
    return json({error: "No se pudo procesar la demostración"}, 500);
  }
}
if (import.meta.main) Deno.serve(demoAppointments);
