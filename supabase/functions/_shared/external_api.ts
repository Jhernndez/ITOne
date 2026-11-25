import { lookup } from "node:dns/promises";
import { request as httpsRequest } from "node:https";
import { isIP } from "node:net";

export class ExternalApiError extends Error {
  constructor(
    message: string,
    public status = 400,
    public outcome: "not_sent" | "unknown" | "responded" = "not_sent",
  ) {
    super(message);
  }
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Database = { from(table: string): any };
export interface ExternalResourceInput {
  tenantId: string;
  resourceId: string;
  query?: Record<string, string | number | boolean | null>;
  body?: Json;
  automation: boolean;
  idempotencyKey?: string;
}
export interface ExternalApiResult {
  ok: boolean;
  status_code: number;
  body: Json;
}

const methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
const maxRequest = 64 * 1024;
const maxResponse = 256 * 1024;
const timeout = 10000;

export function safeBaseUrl(value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ExternalApiError("URL base inválida");
  }
  if (
    url.protocol !== "https:" || url.username || url.password || url.search ||
    url.hash || url.port && url.port !== "443" ||
    !url.hostname.includes(".") || isIP(url.hostname.replace(/^\[|\]$/g, "")) ||
    /(^|\.)(localhost|local|internal|localhost\.localdomain)$/i.test(
      url.hostname,
    )
  ) {
    throw new ExternalApiError(
      "La URL debe usar HTTPS, un dominio público y puerto 443",
    );
  }
  return url;
}

export function resourceUrl(base: string, path: string, query: unknown): URL {
  const url = safeBaseUrl(base);
  if (
    typeof path !== "string" || !path.startsWith("/") ||
    path.startsWith("//") ||
    /[\\?#\x00-\x20]/.test(path) || /%25/i.test(path) || path.length > 2048
  ) {
    throw new ExternalApiError("Ruta de recurso inválida");
  }
  let decoded = path;
  try {
    for (let i = 0; i < 3; i++) decoded = decodeURIComponent(decoded);
  } catch {
    throw new ExternalApiError("Ruta de recurso inválida");
  }
  if (
    /[\\?#\x00-\x20]/.test(decoded) || decoded.startsWith("//") ||
    decoded.split("/").some((part) => part === "." || part === "..")
  ) {
    throw new ExternalApiError("Ruta de recurso inválida");
  }
  url.pathname = url.pathname.replace(/\/$/, "") + path;
  if (query !== undefined) {
    if (
      !query || typeof query !== "object" || Array.isArray(query) ||
      Object.keys(query).length > 32
    ) {
      throw new ExternalApiError(
        "Query debe ser un objeto JSON de valores simples",
      );
    }
    for (const [key, value] of Object.entries(query)) {
      if (
        !key || key.length > 100 || value !== null &&
          !["string", "number", "boolean"].includes(typeof value) ||
        typeof value === "number" && !Number.isFinite(value) ||
        String(value).length > 2048
      ) {
        throw new ExternalApiError("Parámetro de consulta inválido");
      }
      if (value !== null) url.searchParams.set(key, String(value));
    }
  }
  if (url.href.length > 8192) throw new ExternalApiError("URL demasiado larga");
  return url;
}

export function isPublicIpv4(address: string): boolean {
  if (isIP(address) !== 4) return false;
  const [a, b, c] = address.split(".").map(Number);
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    a === 100 && b >= 64 && b <= 127 || a === 169 && b === 254 ||
    a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 ||
    a === 192 && b === 0 || a === 192 && b === 88 && c === 99 ||
    a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) ||
    a === 203 && b === 0 && c === 113);
}

export function authHeaders(
  type: string,
  config: Record<string, unknown>,
): Record<string, string> {
  const field = (key: string) => {
    const value = config[key];
    if (
      typeof value !== "string" || !value || value.length > 4096 ||
      /[\r\n]/.test(value)
    ) {
      throw new ExternalApiError("Credenciales incompletas o inválidas");
    }
    return value;
  };
  if (type === "none") return {};
  if (type === "bearer_token") {
    return { authorization: `Bearer ${field("token")}` };
  }
  if (type === "basic") {
    return {
      authorization: `Basic ${
        btoa(
          unescape(
            encodeURIComponent(`${field("username")}:${field("password")}`),
          ),
        )
      }`,
    };
  }
  if (type === "api_key") {
    const name = field("header_name");
    if (
      !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) ||
      /^(host|content-length|connection|transfer-encoding|content-type|idempotency-key|proxy-authorization)$/i
        .test(name)
    ) {
      throw new ExternalApiError("Nombre de cabecera no permitido");
    }
    return { [name]: field("header_value") };
  }
  throw new ExternalApiError("Tipo de autenticación no soportado");
}

export function mergeCredentials(
  type: string,
  incoming: unknown,
  existing?: { auth_type: string; auth_config: Record<string, unknown> },
): Record<string, unknown> {
  const allowed: Record<string, string[]> = {
    none: [],
    api_key: ["header_name", "header_value"],
    bearer_token: ["token"],
    basic: ["username", "password"],
  };
  if (!Object.hasOwn(allowed, type)) {
    throw new ExternalApiError("Tipo de autenticación no soportado");
  }
  if (!incoming || typeof incoming !== "object" || Array.isArray(incoming)) {
    throw new ExternalApiError("Credenciales inválidas");
  }
  const config = existing?.auth_type === type
    ? { ...existing.auth_config }
    : {};
  for (const [key, value] of Object.entries(incoming)) {
    if (!allowed[type].includes(key) || typeof value !== "string") {
      throw new ExternalApiError("Credenciales inválidas");
    }
    if (value !== "") config[key] = value;
  }
  if (type === "none") return {};
  authHeaders(type, config);
  return config;
}

// DNS is resolved once, checked, and pinned via Node's lookup callback. TLS still
// verifies the original hostname; redirects are never followed.
export async function sendExternalApiRequest(
  url: URL,
  method: string,
  headers: Record<string, string>,
  body?: string,
  dependencies: {
    resolve: typeof lookup;
    request: typeof httpsRequest;
    timeoutMs: number;
  } = {
    resolve: lookup,
    request: httpsRequest,
    timeoutMs: timeout,
  },
): Promise<{ status: number; text: string }> {
  let timer: ReturnType<typeof setTimeout>;
  let req: ReturnType<typeof httpsRequest> | undefined;
  let expired = false;
  try {
    return await Promise.race([
      (async () => {
        let addresses;
        try {
          addresses = await dependencies.resolve(url.hostname, {
            all: true,
            family: 4,
          });
        } catch {
          throw new ExternalApiError(
            "No se pudo resolver el dominio público",
            502,
          );
        }
        if (expired) {
          throw new ExternalApiError("Tiempo de espera agotado", 504);
        }
        if (
          !addresses.length ||
          addresses.some((item) => !isPublicIpv4(item.address))
        ) {
          throw new ExternalApiError(
            "El dominio resuelve a una dirección no permitida",
            400,
          );
        }
        return await new Promise<{ status: number; text: string }>(
          (resolve, reject) => {
            req = dependencies.request(url, {
              method,
              headers,
              family: 4,
              agent: false,
              lookup: (_host, _options, callback) =>
                callback(null, addresses[0].address, 4),
            }, (response) => {
              const status = response.statusCode ?? 502;
              if (status >= 300 && status < 400) {
                response.destroy();
                reject(
                  new ExternalApiError(
                    "Redirección bloqueada",
                    502,
                    "responded",
                  ),
                );
                return;
              }
              const chunks: Uint8Array[] = [];
              let size = 0;
              response.on("data", (chunk: Uint8Array) => {
                size += chunk.length;
                if (size > maxResponse) {
                  response.destroy();
                  reject(
                    new ExternalApiError(
                      "Respuesta externa demasiado grande",
                      502,
                      "responded",
                    ),
                  );
                } else chunks.push(chunk);
              });
              response.on("error", () =>
                reject(
                  new ExternalApiError(
                    "Error leyendo la respuesta externa",
                    502,
                    "unknown",
                  ),
                ));
              response.on("end", () =>
                resolve({
                  status,
                  text: Buffer.concat(chunks).toString("utf8"),
                }));
            });
            req.on("error", () =>
              reject(
                new ExternalApiError(
                  "No se pudo conectar con la API externa",
                  502,
                  "unknown",
                ),
              ));
            if (body !== undefined) {
              req.write(body);
            }
            req.end();
          },
        );
      })(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          expired = true;
          req?.destroy();
          reject(
            new ExternalApiError(
              "Tiempo de espera agotado",
              504,
              req ? "unknown" : "not_sent",
            ),
          );
        }, dependencies.timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer!);
  }
}

type Integration = {
  base_url: string;
  auth_type: string;
  auth_config: Record<string, unknown>;
  enabled: boolean;
};
type Resource = {
  integration_id: string;
  path: string;
  http_method: string;
  enabled: boolean;
  enabled_for_automation: boolean;
  allow_automation_writes: boolean;
};
type Transport = typeof sendExternalApiRequest;

function validateJson(
  value: unknown,
  seen = new Set<object>(),
  depth = 0,
): void {
  if (depth > 50) throw new ExternalApiError("Cuerpo JSON demasiado anidado");
  if (
    value === null || typeof value === "string" || typeof value === "boolean" ||
    typeof value === "number" && Number.isFinite(value)
  ) return;
  if (typeof value !== "object" || seen.has(value)) {
    throw new ExternalApiError("Cuerpo JSON inválido");
  }
  if (
    !Array.isArray(value) && Object.getPrototypeOf(value) !== Object.prototype
  ) {
    throw new ExternalApiError("Cuerpo JSON inválido");
  }
  seen.add(value);
  for (const child of Object.values(value)) {
    validateJson(child, seen, depth + 1);
  }
  seen.delete(value);
}

export async function executeExternalRequest(
  integration: Integration,
  resource: Pick<Resource, "path" | "http_method">,
  query?: ExternalResourceInput["query"],
  body?: Json,
  idempotencyKey?: string,
  transport: Transport = sendExternalApiRequest,
): Promise<ExternalApiResult> {
  const method = resource.http_method;
  if (!methods.includes(method)) {
    throw new ExternalApiError("Método HTTP inválido");
  }
  const url = resourceUrl(integration.base_url, resource.path, query);
  const headers = authHeaders(
    integration.auth_type,
    integration.auth_config ?? {},
  );
  if (idempotencyKey !== undefined) {
    if (!/^[A-Za-z0-9._:-]{1,200}$/.test(idempotencyKey)) {
      throw new ExternalApiError("Clave de idempotencia inválida");
    }
    headers["idempotency-key"] = idempotencyKey;
  }
  let serialized: string | undefined;
  if (method !== "GET" && body !== undefined) {
    validateJson(body);
    try {
      serialized = JSON.stringify(body);
    } catch {
      throw new ExternalApiError("Cuerpo JSON inválido");
    }
    if (
      serialized === undefined ||
      new TextEncoder().encode(serialized).length > maxRequest
    ) {
      throw new ExternalApiError("Cuerpo JSON demasiado grande o inválido");
    }
    headers["content-type"] = "application/json";
  }
  const response = await transport(url, method, headers, serialized);
  // An upstream may echo request credentials; never return those to the client.
  const rawSecrets = [
    ...Object.values(integration.auth_config ?? {}),
    ...Object.values(
      authHeaders(integration.auth_type, integration.auth_config ?? {}),
    ),
  ]
    .filter((value): value is string =>
      typeof value === "string" && value.length > 0
    );
  const secrets = [
    ...new Set(rawSecrets.flatMap((secret) => [
      secret,
      encodeURIComponent(secret),
      JSON.stringify(secret).slice(1, -1),
      Buffer.from(secret, "utf8").toString("base64"),
      ...(secret.startsWith("Basic ") ? [secret.slice(6)] : []),
    ])),
  ].sort((a, b) => b.length - a.length);
  const redact = (value: string) => {
    for (const secret of secrets) {
      value = value.split(secret).join("[REDACTED]");
    }
    return value;
  };
  const clean = (value: Json): Json => {
    if (typeof value === "string") return redact(value);
    if (Array.isArray(value)) return value.map(clean);
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map((
          [key, child],
        ) => [redact(key), clean(child)]),
      );
    }
    return value;
  };
  let result: Json;
  try {
    result = clean(JSON.parse(response.text));
  } catch {
    result = redact(response.text);
  }
  return {
    ok: response.status >= 200 && response.status < 300,
    status_code: response.status,
    body: result,
  };
}

export async function executeExternalResource(
  admin: Database,
  input: ExternalResourceInput,
): Promise<ExternalApiResult> {
  if (
    !input || typeof input.tenantId !== "string" || !input.tenantId ||
    typeof input.resourceId !== "string" || !input.resourceId ||
    typeof input.automation !== "boolean"
  ) {
    throw new ExternalApiError(
      "Tenant, recurso y modo de ejecución son obligatorios",
    );
  }
  const { data: resource, error: resourceError } = await admin.from(
    "tenant_api_resources",
  )
    .select(
      "integration_id,path,http_method,enabled,enabled_for_automation,allow_automation_writes",
    )
    .eq("tenant_id", input.tenantId).eq("id", input.resourceId).maybeSingle();
  if (resourceError) {
    throw new ExternalApiError("No se pudo consultar el recurso", 500);
  }
  if (!resource || !resource.enabled) {
    throw new ExternalApiError("Recurso no encontrado o deshabilitado", 404);
  }
  if (
    input.automation && (!resource.enabled_for_automation ||
      resource.http_method !== "GET" && !resource.allow_automation_writes)
  ) {
    throw new ExternalApiError(
      "Recurso no autorizado para esta automatización",
      403,
    );
  }
  const { data: integration, error: integrationError } = await admin.from(
    "tenant_api_integrations",
  )
    .select("base_url,auth_type,auth_config,enabled").eq(
      "tenant_id",
      input.tenantId,
    )
    .eq("id", resource.integration_id).maybeSingle();
  if (integrationError) {
    throw new ExternalApiError("No se pudo consultar la integración", 500);
  }
  if (!integration || !integration.enabled) {
    throw new ExternalApiError(
      "Integración no encontrada o deshabilitada",
      404,
    );
  }
  return await executeExternalRequest(
    integration,
    resource,
    input.query,
    input.body,
    input.idempotencyKey,
  );
}
