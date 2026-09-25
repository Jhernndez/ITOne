import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Manages tenant-scoped internal API integrations that require secret
// credentials (API key, bearer token, basic auth). Credentials are only ever
// written/read by this function using the service role key; the Flutter
// frontend never receives `auth_config` back and column-level grants on
// `tenant_api_integrations.auth_config` are revoked for `authenticated`.
//
// Actions:
//   upsert_integration  - create/update an integration, including its secrets.
//   test_connection     - perform a lightweight request against the base URL.
//   execute_resource    - manually invoke one configured resource (path + method).

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

const AUTH_TYPES = ["none", "api_key", "bearer_token", "basic"] as const;
type AuthType = typeof AUTH_TYPES[number];

function isPrivateHost(hostname: string): boolean {
  const lower = hostname.toLowerCase();
  if (["localhost", "127.0.0.1", "0.0.0.0", "::1"].includes(lower)) return true;
  const ipv4 = lower.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const a = Number(ipv4[1]);
    const b = Number(ipv4[2]);
    if (a === 10) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 127) return true;
  }
  return false;
}

function assertSafeUrl(rawUrl: string): URL {
  const url = new URL(rawUrl);
  if (url.protocol !== "https:") {
    throw new Error("Solo se permiten URLs https://");
  }
  if (isPrivateHost(url.hostname)) {
    throw new Error("El destino de la API no es válido (host privado o reservado)");
  }
  return url;
}

function buildAuthHeaders(
  authType: AuthType,
  authConfig: Record<string, unknown>,
): Record<string, string> {
  switch (authType) {
    case "api_key": {
      const headerName = String(authConfig.header_name ?? "X-API-Key").trim() || "X-API-Key";
      const headerValue = String(authConfig.header_value ?? "");
      return { [headerName]: headerValue };
    }
    case "bearer_token": {
      const token = String(authConfig.token ?? "");
      return { Authorization: `Bearer ${token}` };
    }
    case "basic": {
      const username = String(authConfig.username ?? "");
      const password = String(authConfig.password ?? "");
      return { Authorization: `Basic ${btoa(`${username}:${password}`)}` };
    }
    default:
      return {};
  }
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs = 8000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return json({ error: "Supabase secrets are not configured" }, 500);
  }

  try {
    const authHeader = request.headers.get("Authorization");
    if (!authHeader) return json({ error: "Authentication required" }, 401);
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) return json({ error: "Authentication required" }, 401);

    const body = await request.json();
    const action = body?.action;
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
    const isTenantAdmin =
      membership?.role === "tenant_admin" ||
      platformMembership?.role === "platform_owner" ||
      platformMembership?.role === "platform_admin";
    if (!isTenantAdmin) {
      return json({ error: "Solo un administrador del tenant puede gestionar APIs internas" }, 403);
    }

    if (action === "upsert_integration") {
      const integrationId = body?.integration_id as string | undefined;
      const name = String(body?.name ?? "").trim();
      const baseUrl = String(body?.base_url ?? "").trim();
      const authType = String(body?.auth_type ?? "none") as AuthType;
      const incomingAuthConfig = (body?.auth_config ?? {}) as Record<string, unknown>;
      const enabled = body?.enabled !== false;

      if (!name || !baseUrl) {
        return json({ error: "Nombre y URL base son obligatorios" }, 400);
      }
      if (!AUTH_TYPES.includes(authType)) {
        return json({ error: "Tipo de autenticación no soportado" }, 400);
      }
      try {
        assertSafeUrl(baseUrl);
      } catch (error) {
        return json({ error: (error as Error).message }, 400);
      }

      let authConfig: Record<string, unknown> = incomingAuthConfig;
      if (integrationId) {
        // Preserve previously stored secret fields when the admin leaves a
        // field blank while editing (frontend never receives the original
        // secrets back, so blank means "keep current value").
        const { data: existing } = await adminClient
          .from("tenant_api_integrations")
          .select("auth_type, auth_config")
          .eq("id", integrationId)
          .eq("tenant_id", tenantId)
          .maybeSingle();
        const existingConfig = (existing?.auth_config ?? {}) as Record<string, unknown>;
        if (existing?.auth_type === authType) {
          authConfig = { ...existingConfig };
          for (const [key, value] of Object.entries(incomingAuthConfig)) {
            if (typeof value === "string" && value.trim() === "") continue;
            authConfig[key] = value;
          }
        }
      }

      const payload = {
        tenant_id: tenantId,
        name,
        base_url: baseUrl,
        auth_type: authType,
        auth_config: authConfig,
        enabled,
        updated_at: new Date().toISOString(),
      };

      if (integrationId) {
        const { error } = await adminClient
          .from("tenant_api_integrations")
          .update(payload)
          .eq("id", integrationId)
          .eq("tenant_id", tenantId);
        if (error) throw error;
        return json({ ok: true, integration_id: integrationId });
      } else {
        const { data, error } = await adminClient
          .from("tenant_api_integrations")
          .insert(payload)
          .select("id")
          .single();
        if (error) throw error;
        return json({ ok: true, integration_id: data.id });
      }
    }

    if (action === "test_connection") {
      const integrationId = body?.integration_id as string | undefined;
      if (!integrationId) return json({ error: "integration_id es requerido" }, 400);
      const { data: integration, error } = await adminClient
        .from("tenant_api_integrations")
        .select("base_url, auth_type, auth_config")
        .eq("id", integrationId)
        .eq("tenant_id", tenantId)
        .maybeSingle();
      if (error) throw error;
      if (!integration) return json({ error: "Integración no encontrada" }, 404);

      let url: URL;
      try {
        url = assertSafeUrl(integration.base_url);
      } catch (urlError) {
        return json({ ok: false, message: (urlError as Error).message }, 200);
      }
      const headers = buildAuthHeaders(
        integration.auth_type as AuthType,
        (integration.auth_config ?? {}) as Record<string, unknown>,
      );
      try {
        const response = await fetchWithTimeout(url.toString(), { method: "GET", headers });
        return json({
          ok: response.ok,
          status_code: response.status,
          message: response.ok
            ? "Conexión exitosa."
            : `El servidor respondió con estado ${response.status}.`,
        });
      } catch (fetchError) {
        return json({
          ok: false,
          message: `No fue posible conectar: ${(fetchError as Error).message}`,
        });
      }
    }

    if (action === "execute_resource") {
      const integrationId = body?.integration_id as string | undefined;
      const resourceId = body?.resource_id as string | undefined;
      if (!integrationId || !resourceId) {
        return json({ error: "integration_id y resource_id son requeridos" }, 400);
      }
      const { data: integration, error: integrationError } = await adminClient
        .from("tenant_api_integrations")
        .select("base_url, auth_type, auth_config, enabled")
        .eq("id", integrationId)
        .eq("tenant_id", tenantId)
        .maybeSingle();
      if (integrationError) throw integrationError;
      if (!integration || !integration.enabled) {
        return json({ error: "Integración no encontrada o deshabilitada" }, 404);
      }
      const { data: resource, error: resourceError } = await adminClient
        .from("tenant_api_resources")
        .select("path, http_method, enabled")
        .eq("id", resourceId)
        .eq("tenant_id", tenantId)
        .eq("integration_id", integrationId)
        .maybeSingle();
      if (resourceError) throw resourceError;
      if (!resource || !resource.enabled) {
        return json({ error: "Recurso no encontrado o deshabilitado" }, 404);
      }

      let url: URL;
      try {
        url = assertSafeUrl(integration.base_url.replace(/\/$/, "") + resource.path);
      } catch (urlError) {
        return json({ ok: false, message: (urlError as Error).message }, 200);
      }
      const query = (body?.query ?? {}) as Record<string, unknown>;
      for (const [key, value] of Object.entries(query)) {
        if (value !== null && value !== undefined) url.searchParams.set(key, String(value));
      }

      const headers: Record<string, string> = {
        ...buildAuthHeaders(
          integration.auth_type as AuthType,
          (integration.auth_config ?? {}) as Record<string, unknown>,
        ),
      };
      const method = resource.http_method as string;
      const hasBody = ["POST", "PUT", "PATCH"].includes(method) && body?.body !== undefined;
      if (hasBody) headers["Content-Type"] = "application/json";

      try {
        const response = await fetchWithTimeout(url.toString(), {
          method,
          headers,
          body: hasBody ? JSON.stringify(body.body) : undefined,
        });
        const text = await response.text();
        return json({
          ok: response.ok,
          status_code: response.status,
          response_preview: text.slice(0, 4000),
        });
      } catch (fetchError) {
        return json({
          ok: false,
          message: `No fue posible ejecutar el recurso: ${(fetchError as Error).message}`,
        });
      }
    }

    return json({ error: "Acción no soportada" }, 400);
  } catch (error) {
    console.error("manage-internal-api error", error);
    return json({ error: "Error inesperado gestionando la API interna" }, 500);
  }
});
