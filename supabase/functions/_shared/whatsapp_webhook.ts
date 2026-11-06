export type ObjectValue = Record<string, unknown>;

export function object(value: unknown): ObjectValue {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as ObjectValue : {};
}

export function objects(value: unknown): ObjectValue[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new Error("Expected WhatsApp event array");
  return value.map(object);
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

export function phone(value: unknown): string | null {
  const number = text(value)?.replace(/[+\s()-]/g, "");
  return number && /^\d+$/.test(number) ? number : null;
}

export function isoTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d+$/.test(value)) return null;
  const date = new Date(Number(value) * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

export function extractMessageBody(message: ObjectValue): string | null {
  const content = object(message[String(message.type)]);
  switch (message.type) {
    case "text": return text(content.body);
    case "image": return text(content.caption) ?? "[Imagen recibida]";
    case "video": return text(content.caption) ?? "[Video recibido]";
    case "audio": return "[Audio recibido]";
    case "voice": return "[Nota de voz recibida]";
    case "sticker": return "[Sticker recibido]";
    case "document": return text(content.caption) ??
      (text(content.filename) ? `[Documento: ${content.filename}]` : "[Documento recibido]");
    case "location": return text(content.name)
      ? `[Ubicación: ${content.name}]` : `[Ubicación: ${content.latitude}, ${content.longitude}]`;
    case "contacts": {
      const names = objects(message.contacts).map((contact) => text(object(contact.name).formatted_name)).filter(Boolean);
      return names.length ? `[Contacto: ${names.join(", ")}]` : "[Contacto recibido]";
    }
    case "button": return text(content.text) ?? "[Respuesta de botón]";
    case "interactive": {
      const reply = text(object(content.button_reply).title) ?? text(object(content.list_reply).title);
      return reply ? `[Respuesta: ${reply}]` : "[Mensaje interactivo recibido]";
    }
    case "reaction": return text(content.emoji) ? `[Reacción: ${content.emoji}]` : "[Reacción recibida]";
    case "system": return text(content.body) ?? "[Notificación del sistema]";
    case "revoke": return "[Mensaje eliminado desde WhatsApp Business]";
    case "edit": return extractMessageBody(object(content.message)) ?? "[Mensaje editado]";
    case "unsupported": {
      const error = objects(message.errors)[0];
      const reason = error ? [text(error.title), text(error.message)].filter(Boolean).join(": ") : "";
      return reason
        ? `[Mensaje no compatible con la API de WhatsApp: ${reason}. Ábrelo desde la app de WhatsApp del número para leerlo.]`
        : "[Mensaje no compatible con la API de WhatsApp. Ábrelo desde la app de WhatsApp del número para leerlo.]";
    }
    default: return `[Mensaje de tipo ${text(message.type) ?? "desconocido"} no disponible en ITONE]`;
  }
}

type Direction = "inbound" | "outbound";
type Source = "cloud_api" | "business_app" | "history";

export interface NormalizedMessage {
  provider_message_id: string;
  phone_number: string | null;
  user_id: string | null;
  profile_name: string | null;
  direction: Direction;
  message_type: string;
  body: string | null;
  timestamp: string | null;
  delivery_status: string;
  source: Source;
  original_message_id: string | null;
}

export function normalizeMessages(field: string, value: ObjectValue): NormalizedMessage[] {
  const result: NormalizedMessage[] = [];
  const contacts = objects(value.contacts);
  const add = (
    message: ObjectValue, direction: Direction, source: Source,
    contactPhone: string | null, userId: string | null,
  ) => {
    const id = text(message.id);
    if (!id || (!contactPhone && !userId)) throw new Error("WhatsApp message lacks an ID or contact identity");
    const profile = contacts.find((contact) =>
      (contactPhone && phone(contact.wa_id) === contactPhone) ||
      (userId && contact.user_id === userId)
    );
    const status = String(object(message.history_context).status ?? "").toLowerCase();
    const statuses: Record<string, string> = {
      delivered: "delivered", read: "read", played: "read", sent: "sent",
      error: "failed", pending: "accepted",
    };
    result.push({
      provider_message_id: id,
      phone_number: contactPhone,
      user_id: userId,
      profile_name: text(object(profile?.profile).name) ?? text(object(profile?.profile).username),
      direction,
      message_type: text(message.type) ?? "unknown",
      body: extractMessageBody(message),
      timestamp: isoTimestamp(message.timestamp),
      delivery_status: source === "history" ? statuses[status] ?? "accepted" :
        direction === "outbound" ? "sent" : "accepted",
      source,
      original_message_id: text(object(message.edit ?? message.revoke).original_message_id),
    });
  };
  for (const message of objects(value.messages)) {
    add(message, "inbound", field === "history" ? "history" : "cloud_api",
      phone(message.from), text(message.from_user_id));
  }
  for (const message of objects(value.message_echoes)) {
    add(message, "outbound", field === "history" ? "history" : "business_app",
      phone(message.to), text(message.to_user_id));
  }
  for (const chunk of objects(value.history)) {
    for (const thread of objects(chunk.threads)) {
      const context = object(thread.context);
      const contactPhone = phone(context.wa_id) ?? phone(thread.id);
      const userId = text(context.user_id);
      for (const message of objects(thread.messages)) {
        const from = phone(message.from);
        const businessPhone = phone(object(value.metadata).display_phone_number);
        let direction: Direction;
        if (text(message.from_user_id) || (contactPhone && from === contactPhone)) {
          direction = "inbound";
        } else if (from && businessPhone && from === businessPhone) {
          direction = "outbound";
        } else {
          throw new Error("Cannot determine history message direction");
        }
        add(message, direction, "history", contactPhone, userId);
      }
    }
  }
  return result;
}

export function historyState(value: ObjectValue) {
  let progress: number | null = null;
  let error: string | null = null;
  let declined = false;
  for (const chunk of objects(value.history)) {
    const metadata = object(chunk.metadata);
    if (typeof metadata.progress === "number") {
      progress = Math.max(progress ?? 0, Math.min(100, Math.max(0, metadata.progress)));
    }
    for (const detail of objects(chunk.errors)) {
      declined ||= String(detail.code) === "2593109";
      error = text(object(detail.error_data).details) ?? text(detail.message) ?? text(detail.title) ??
        `Meta history error ${detail.code}`;
    }
  }
  return { progress, error, declined };
}

export async function validSignature(raw: string, signature: string | null, secret: string) {
  if (!signature || !/^sha256=[0-9a-f]{64}$/.test(signature)) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
  );
  const bytes = Uint8Array.from(signature.slice(7).match(/../g)!, (hex) => parseInt(hex, 16));
  return crypto.subtle.verify("HMAC", key, bytes, new TextEncoder().encode(raw));
}
