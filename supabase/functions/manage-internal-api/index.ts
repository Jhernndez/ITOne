import {
  corsHeaders,
  json,
  requireTenantAdmin,
  WhatsAppError,
} from "../_shared/whatsapp.ts";
import {
  executeExternalRequest,
  executeExternalResource,
  ExternalApiError,
  mergeCredentials,
  safeBaseUrl,
} from "../_shared/external_api.ts";

async function readBody(request: Request): Promise<string> {
  const reader = request.body?.getReader();
  if (!reader) throw new ExternalApiError("JSON inválido");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 96 * 1024) {
      await reader.cancel();
      throw new ExternalApiError("Solicitud demasiado grande", 413);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Método no permitido" }, 405);
  }
  try {
    const raw = await readBody(request);
    let input: Record<string, any>;
    try {
      input = JSON.parse(raw);
    } catch {
      throw new ExternalApiError("JSON inválido");
    }
    if (
      !input || typeof input !== "object" || Array.isArray(input) ||
      typeof input.tenant_id !== "string" || !input.tenant_id
    ) {
      throw new ExternalApiError("tenant_id es obligatorio");
    }
    const admin = await requireTenantAdmin(request, input.tenant_id);
    if (input.action === "upsert_integration") {
      const { integration_id: id, tenant_id: tenantId, auth_type: type } =
        input;
      const name = typeof input.name === "string" ? input.name.trim() : "";
      const base = typeof input.base_url === "string"
        ? input.base_url.trim()
        : "";
      if (!name || name.length > 120 || base.length > 2048) {
        throw new ExternalApiError("Nombre o URL inválidos");
      }
      safeBaseUrl(base);
      if (!["none", "api_key", "bearer_token", "basic"].includes(type)) {
        throw new ExternalApiError("Tipo de autenticación no soportado");
      }
      if (id !== undefined && (typeof id !== "string" || !id)) {
        throw new ExternalApiError("Identificador inválido");
      }
      let existingIntegration;
      if (id) {
        const { data: existing, error } = await admin.from(
          "tenant_api_integrations",
        )
          .select("auth_type,auth_config").eq("id", id).eq(
            "tenant_id",
            tenantId,
          ).maybeSingle();
        if (error) throw error;
        if (!existing) {
          throw new ExternalApiError("Integración no encontrada", 404);
        }
        existingIntegration = existing;
      }
      const config = mergeCredentials(
        type,
        input.auth_config ?? {},
        existingIntegration,
      );
      const payload = {
        tenant_id: tenantId,
        name,
        base_url: base,
        auth_type: type,
        auth_config: config,
        enabled: input.enabled !== false,
        updated_at: new Date().toISOString(),
      };
      const result = id
        ? await admin.from("tenant_api_integrations").update(payload).eq(
          "tenant_id",
          tenantId,
        ).eq("id", id).select("id").single()
        : await admin.from("tenant_api_integrations").insert(payload).select(
          "id",
        ).single();
      if (result.error) throw result.error;
      return json({ ok: true, integration_id: result.data.id });
    }
    if (input.action === "execute_resource") {
      if (typeof input.resource_id !== "string" || !input.resource_id) {
        throw new ExternalApiError("resource_id es obligatorio");
      }
      const result = await executeExternalResource(admin, {
        tenantId: input.tenant_id,
        resourceId: input.resource_id,
        query: input.query,
        body: input.body,
        automation: false,
      });
      return json({ ...result });
    }
    if (input.action === "test_connection") {
      if (typeof input.integration_id !== "string" || !input.integration_id) {
        throw new ExternalApiError("integration_id es obligatorio");
      }
      const { data, error } = await admin.from("tenant_api_integrations")
        .select("base_url,auth_type,auth_config,enabled").eq(
          "tenant_id",
          input.tenant_id,
        )
        .eq("id", input.integration_id).maybeSingle();
      if (error) throw error;
      if (!data || !data.enabled) {
        throw new ExternalApiError(
          "Integración no encontrada o deshabilitada",
          404,
        );
      }
      return json({
        ...await executeExternalRequest(data, {
          path: "/",
          http_method: "GET",
        }),
      });
    }
    throw new ExternalApiError("Acción no soportada");
  } catch (error) {
    if (error instanceof ExternalApiError || error instanceof WhatsAppError) {
      return json({
        error: error.message,
        ...(error instanceof ExternalApiError
          ? { outcome: error.outcome }
          : {}),
      }, error.status);
    }
    console.error("manage-internal-api: error interno");
    return json({ error: "No fue posible gestionar la API" }, 500);
  }
});
