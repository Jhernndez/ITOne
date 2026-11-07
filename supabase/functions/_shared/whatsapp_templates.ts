export class TemplateError extends Error {
  constructor(message: string, public status = 400) {
    super(message);
  }
}
export interface TemplateInput {
  name: string;
  language: string;
  category: string;
  body: string;
  header: string;
  footer: string;
  body_examples: string[];
  header_example: string;
  buttons: { type: string; text: string; value: string }[];
}
const languages = new Set(["es", "es_ES", "es_MX", "en_US", "pt_BR"]);
export function parseTemplate(value: unknown): TemplateInput {
  if (!value || typeof value !== "object") {
    throw new TemplateError("Plantilla no válida.");
  }
  const v = value as Record<string, unknown>;
  const text = (key: string, max: number, required = false) => {
    const s = v[key] ?? "";
    if (typeof s !== "string" || s.length > max || (required && !s.trim())) {
      throw new TemplateError(`Campo ${key} no válido (máximo ${max}).`);
    }
    return s.trim();
  };
  const result: TemplateInput = {
    name: text("name", 512, true),
    language: text("language", 10, true),
    category: text("category", 20, true),
    body: text("body", 1024, true),
    header: text("header", 60),
    footer: text("footer", 60),
    header_example: text("header_example", 200),
    body_examples: [],
    buttons: [],
  };
  if (
    !/^[a-z0-9_]+$/.test(result.name) || !languages.has(result.language) ||
    !["UTILITY", "MARKETING"].includes(result.category)
  ) {
    throw new TemplateError("Nombre, idioma o categoría no válidos.");
  }
  if (
    !Array.isArray(v.body_examples) ||
    v.body_examples.some((s) =>
      typeof s !== "string" || !s.trim() || s.length > 200
    )
  ) {
    throw new TemplateError("Usa ejemplos ficticios de hasta 200 caracteres.");
  }
  result.body_examples = v.body_examples.map((s) => (s as string).trim());
  function variables(s: string): number {
    const matches = [...s.matchAll(/\{\{([1-9]\d*)\}\}/g)];
    if (s.replace(/\{\{[1-9]\d*\}\}/g, "").match(/[{}]/)) {
      throw new TemplateError(
        "Variables numéricas: {{1}}, {{2}}, sin llaves sueltas.",
      );
    }
    const ids = [...new Set(matches.map((m) => Number(m[1])))].sort((a, b) =>
      a - b
    );
    if (ids.length > 20 || ids.some((n, i) => n !== i + 1)) {
      throw new TemplateError(
        "Las variables deben ser consecutivas desde {{1}} (máximo 20).",
      );
    }
    return ids.length;
  }
  if (variables(result.body) !== result.body_examples.length) {
    throw new TemplateError("Incluye un ejemplo por cada variable del cuerpo.");
  }
  const headerCount = variables(result.header);
  if (headerCount > 1 || (headerCount === 1 && !result.header_example)) {
    throw new TemplateError(
      "El encabezado admite una variable {{1}} con su ejemplo.",
    );
  }
  if (/[{}]/.test(result.footer)) {
    throw new TemplateError("El pie no admite variables.");
  }
  if (!Array.isArray(v.buttons) || v.buttons.length > 3) {
    throw new TemplateError("Máximo tres botones.");
  }
  for (const raw of v.buttons) {
    if (!raw || typeof raw !== "object") {
      throw new TemplateError("Botón no válido.");
    }
    const b = raw as Record<string, unknown>;
    if (
      typeof b.text !== "string" || !b.text.trim() || b.text.length > 25 ||
      typeof b.value !== "string" || typeof b.type !== "string" ||
      !["QUICK_REPLY", "URL", "PHONE_NUMBER"].includes(b.type)
    ) {
      throw new TemplateError("Botón no válido: texto de hasta 25 caracteres.");
    }
    if (b.type === "URL") {
      let url: URL;
      try {
        url = new URL(b.value);
      } catch {
        throw new TemplateError("URL de botón no válida.");
      }
      if (
        url.protocol !== "https:" || url.username || url.password ||
        b.value.length > 2000 ||
        /[{}]/.test(b.value)
      ) {
        throw new TemplateError(
          "Usa una URL HTTPS fija sin credenciales ni variables.",
        );
      }
    }
    if (b.type === "PHONE_NUMBER" && !/^\+[1-9]\d{7,14}$/.test(b.value)) {
      throw new TemplateError("Teléfono del botón en formato +573001234567.");
    }
    result.buttons.push({
      type: b.type,
      text: b.text.trim(),
      value: b.value.trim(),
    });
  }
  const types = result.buttons.map((b) => b.type);
  if (
    (types.includes("QUICK_REPLY") && types.some((t) => t !== "QUICK_REPLY")) ||
    types.filter((t) => t === "URL").length > 2 ||
    types.filter((t) => t === "PHONE_NUMBER").length > 1 ||
    new Set(result.buttons.map((b) => b.text)).size !== result.buttons.length
  ) {
    throw new TemplateError(
      "Usa respuestas rápidas o hasta dos URL y un teléfono, sin etiquetas repetidas.",
    );
  }
  return result;
}
export function templateComponents(t: TemplateInput) {
  const components: Record<string, unknown>[] = [];
  if (t.header) {
    components.push({
      type: "HEADER",
      format: "TEXT",
      text: t.header,
      ...(t.header.includes("{{1}}")
        ? { example: { header_text: [t.header_example] } }
        : {}),
    });
  }
  components.push({
    type: "BODY",
    text: t.body,
    ...(t.body_examples.length
      ? { example: { body_text: [t.body_examples] } }
      : {}),
  });
  if (t.footer) components.push({ type: "FOOTER", text: t.footer });
  if (t.buttons.length) {
    components.push({
      type: "BUTTONS",
      buttons: t.buttons.map((b) => ({
        type: b.type,
        text: b.text,
        ...(b.type === "URL"
          ? { url: b.value }
          : b.type === "PHONE_NUMBER"
          ? { phone_number: b.value }
          : {}),
      })),
    });
  }
  return components;
}

interface Account {
  id: string;
  business_account_id: string;
  access_token: string | null;
  name: string;
}
export interface TemplateDeps {
  authorize(request: Request, tenant: string): Promise<Account[]>;
  fetch: typeof fetch;
  version: string;
}
export function templatesHandler(deps: TemplateDeps) {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  };
  const json = (body: object, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });
  return async (request: Request) => {
    if (request.method === "OPTIONS") return new Response("ok", { headers });
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }
    try {
      let body: Record<string, unknown>;
      try {
        body = await request.json();
      } catch {
        throw new TemplateError("JSON no válido.");
      }
      if (
        !body || typeof body !== "object" ||
        typeof body.tenant_id !== "string" ||
        !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.tenant_id)
      ) {
        throw new TemplateError("Empresa no válida.");
      }
      const accounts = await deps.authorize(request, body.tenant_id);
      if (body.action === "accounts") {
        return json({
          accounts: accounts.map((a) => ({
            id: a.id,
            name: a.name,
            waba_id: a.business_account_id,
          })),
        });
      }
      const account = accounts.find((a) => a.id === body.account_id);
      if (!account) {
        throw new TemplateError("Cuenta no disponible para esta empresa.", 403);
      }
      if (!account.access_token) {
        throw new TemplateError(
          "La cuenta no tiene token propio. Reconecta o configura sus credenciales en el servidor.",
          409,
        );
      }
      if (
        !/^\d+$/.test(account.business_account_id) ||
        !/^v\d+\.\d+$/.test(deps.version)
      ) {
        throw new TemplateError("Configuración de Meta no válida.", 409);
      }
      const graph = async (
        path: string,
        method = "GET",
        data?: object,
      ): Promise<Record<string, unknown>> => {
        let response: Response;
        try {
          response = await deps.fetch(
            `https://graph.facebook.com/${deps.version}/${path}`,
            {
              method,
              headers: {
                Authorization: `Bearer ${account.access_token}`,
                "Content-Type": "application/json",
              },
              body: data ? JSON.stringify(data) : undefined,
              signal: AbortSignal.timeout(20000),
            },
          );
        } catch {
          throw new TemplateError(
            "No se pudo confirmar la respuesta de Meta. Actualiza el listado antes de reintentar.",
            502,
          );
        }
        let result;
        try {
          result = await response.json();
        } catch {
          throw new TemplateError("Respuesta no válida de Meta.", 502);
        }
        if (!result || typeof result !== "object") {
          throw new TemplateError("Respuesta no válida de Meta.", 502);
        }
        if (!response.ok || result.error) {
          const code = typeof result.error?.code === "number"
            ? result.error.code
            : null;
          console.warn("Template Graph rejection", {
            status: response.status,
            code,
          });
          throw new TemplateError(
            `Meta rechazó la operación${
              code ? ` (código ${code})` : ""
            }. Comprueba permisos, estado y restricciones de la plantilla.`,
            400,
          );
        }
        return result;
      };
      const base = `${account.business_account_id}/message_templates`;
      if (body.action === "list") {
        const query = new URLSearchParams({
          fields:
            "id,name,language,status,category,components,parameter_format",
          limit: "25",
        });
        if (body.after != null) {
          if (typeof body.after !== "string" || body.after.length > 2000) {
            throw new TemplateError("Cursor no válido.");
          }
          query.set("after", body.after);
        }
        const result = await graph(`${base}?${query}`);
        if (!Array.isArray(result.data)) {
          throw new TemplateError("Listado no válido de Meta.", 502);
        }
        const paging = result.paging as {
          next?: string;
          cursors?: { after?: string };
        } | undefined;
        return json({
          templates: result.data,
          after: paging?.next ? paging.cursors?.after ?? null : null,
        });
      }
      if (!["create", "edit", "delete"].includes(String(body.action))) {
        throw new TemplateError("Acción no válida.");
      }
      if (body.action === "create") {
        const t = parseTemplate(body.template);
        const result = await graph(base, "POST", {
          name: t.name,
          language: t.language,
          category: t.category,
          components: templateComponents(t),
        });
        if (typeof result.id !== "string") {
          throw new TemplateError(
            "Meta no confirmó el ID de la plantilla. Actualiza antes de reintentar.",
            502,
          );
        }
        return json({
          id: result.id,
          status: result.status ?? "No informado por Meta",
        });
      }
      if (
        typeof body.template_id !== "string" ||
        !/^\d+$/.test(body.template_id) ||
        typeof body.name !== "string" || !/^[a-z0-9_]{1,512}$/.test(body.name)
      ) throw new TemplateError("Identificador de plantilla no válido.");
      // Resolve ownership through this WABA, never trust a template ID from the client.
      const query = new URLSearchParams({
        name: body.name,
        fields: "id,name,language,status,category",
        limit: "100",
      });
      const owned = await graph(`${base}?${query}`);
      const template = Array.isArray(owned.data)
        ? owned.data.find((t: Record<string, unknown>) =>
          t.id === body.template_id && t.name === body.name
        )
        : null;
      if (!template) {
        throw new TemplateError(
          "La plantilla no pertenece a esta cuenta o ya no está disponible.",
          404,
        );
      }
      if (body.action === "delete") {
        const result = await graph(
          `${base}?${new URLSearchParams({
            hsm_id: body.template_id,
            name: body.name,
          })}`,
          "DELETE",
        );
        if (result.success !== true) {
          throw new TemplateError(
            "Meta no confirmó la eliminación. Actualiza el listado.",
            502,
          );
        }
        return json({ success: true });
      }
      const t = parseTemplate(body.template);
      if (
        t.name !== template.name || t.language !== template.language ||
        t.category !== template.category
      ) {
        throw new TemplateError(
          "Nombre, idioma y categoría no se cambian al editar. Crea otra plantilla.",
        );
      }
      const result = await graph(body.template_id, "POST", {
        components: templateComponents(t),
      });
      if (result.success !== true) {
        throw new TemplateError(
          "Meta no confirmó la edición. Actualiza el listado.",
          502,
        );
      }
      return json({ success: true });
    } catch (error) {
      if (error instanceof TemplateError) {
        console.warn("Template operation failed", { status: error.status });
        return json({ error: error.message }, error.status);
      }
      console.error("Unexpected template operation failure");
      return json({ error: "No se pudo gestionar la plantilla." }, 500);
    }
  };
}
