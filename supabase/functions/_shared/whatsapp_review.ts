export class ReviewError extends Error {
  constructor(message: string, public status = 400) {
    super(message);
  }
}

export interface ReviewDependencies {
  env(name: string): string | undefined;
  authorize(request: Request, tenantId: string): Promise<void>;
  reserve(tenantId: string): Promise<void>;
  fetch: typeof fetch;
}

export function reviewHandler(deps: ReviewDependencies) {
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
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") return new Response("ok", { headers });
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }
    try {
      let input: unknown;
      try {
        input = await request.json();
      } catch {
        throw new ReviewError("La solicitud debe contener JSON válido.");
      }
      if (!input || typeof input !== "object" || Array.isArray(input)) {
        throw new ReviewError("Solicitud no válida.");
      }
      const body = input as Record<string, unknown>;
      const tenantId = body.tenant_id;
      if (
        typeof tenantId !== "string" ||
        !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(tenantId) ||
        !["status", "send"].includes(String(body.action))
      ) {
        throw new ReviewError("Empresa o acción no válida.");
      }
      await deps.authorize(request, tenantId);
      if (tenantId !== deps.env("WHATSAPP_REVIEW_TENANT_ID")) {
        throw new ReviewError(
          "Las pruebas de revisión no están habilitadas para esta empresa.",
          403,
        );
      }
      const token = deps.env("WHATSAPP_REVIEW_ACCESS_TOKEN");
      const phoneId = deps.env("WHATSAPP_REVIEW_PHONE_NUMBER_ID");
      const recipient = deps.env("WHATSAPP_REVIEW_RECIPIENT");
      const version = deps.env("META_GRAPH_VERSION") ?? "v25.0";
      if (
        !token || !phoneId || !/^\d+$/.test(phoneId) ||
        !recipient || !/^\d{8,15}$/.test(recipient) ||
        !/^v\d+\.\d+$/.test(version)
      ) {
        throw new ReviewError(
          "Completa los secretos de revisión en Supabase antes de enviar.",
          409,
        );
      }
      const template = {
        name: "jaspers_market_order_confirmation_v1",
        language: { code: "en_US" },
        components: [{
          type: "body",
          parameters: [
            { type: "text", text: "John Doe" },
            { type: "text", text: "123456" },
            { type: "text", text: "Nov 6, 2026" },
          ],
        }],
      };
      if (body.action === "status") {
        return json({
          phone_number_id: phoneId,
          recipient,
          template: template.name,
          language: template.language.code,
        });
      }
      await deps.reserve(tenantId);
      let response: Response;
      try {
        response = await deps.fetch(
          `https://graph.facebook.com/${version}/${phoneId}/messages`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              messaging_product: "whatsapp",
              to: recipient,
              type: "template",
              template,
            }),
            signal: AbortSignal.timeout(20000),
          },
        );
      } catch {
        throw new ReviewError(
          "No se pudo confirmar la respuesta de Meta. Comprueba WhatsApp antes de reintentar.",
          502,
        );
      }
      let data: {
        error?: { code?: number };
        messages?: { id?: string; message_status?: string }[];
      };
      try {
        data = await response.json();
      } catch {
        throw new ReviewError(
          "Meta devolvió una respuesta no válida. Comprueba WhatsApp antes de reintentar.",
          502,
        );
      }
      if (!response.ok || data.error) {
        const code = typeof data.error?.code === "number"
          ? data.error.code
          : null;
        console.error("WhatsApp review rejected", {
          status: response.status,
          code,
        });
        throw new ReviewError(
          `Meta rechazó el envío${
            code ? ` (código ${code})` : ""
          }. Revisa token, destinatario y plantilla en API Setup.`,
          400,
        );
      }
      const id = data.messages?.[0]?.id;
      if (typeof id !== "string" || !id) {
        throw new ReviewError(
          "Meta no devolvió un identificador de mensaje. Comprueba WhatsApp antes de reintentar.",
          502,
        );
      }
      return json({ provider_message_id: id, status: "accepted" });
    } catch (error) {
      if (error instanceof ReviewError) {
        console.warn("WhatsApp review request failed", {
          status: error.status,
        });
        return json({ error: error.message }, error.status);
      }
      console.error("Unexpected WhatsApp review failure");
      return json({ error: "No se pudo procesar la prueba de WhatsApp." }, 500);
    }
  };
}
