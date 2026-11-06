import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export class WhatsAppError extends Error {
  constructor(message: string, public status = 400) {
    super(message);
  }
}

export function graphVersion() {
  return Deno.env.get("META_GRAPH_VERSION") ?? "v23.0";
}

export interface GraphError {
  message?: string;
  code?: number;
}

export async function graph<T>(
  path: string, token: string, method = "GET", body?: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`https://graph.facebook.com/${graphVersion()}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data: { error?: GraphError } = await response.json();
  if (!response.ok || data.error) {
    const code = data.error?.code;
    console.error("WhatsApp Graph request failed", { path: path.split("?")[0], status: response.status, code });
    throw new WhatsAppError(
      `${data.error?.message ?? "Meta rechazó la solicitud"}${code ? ` (Meta ${code})` : ""}`,
    );
  }
  return data as T;
}

export async function requireTenantAdmin(request: Request, tenantId: string) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const auth = request.headers.get("Authorization");
  if (!url || !key) throw new WhatsAppError("Supabase secrets are not configured", 500);
  if (!auth) throw new WhatsAppError("Authentication required", 401);
  const client = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) throw new WhatsAppError("Authentication required", 401);
  const admin = createClient(url, key);
  const { data: disabled, error: disabledError } = await client.rpc("is_current_user_disabled");
  if (disabledError) throw disabledError;
  if (disabled) throw new WhatsAppError("User access is disabled", 403);
  const { data: membership, error: membershipError } = await admin
    .from("tenant_memberships").select("role")
    .eq("tenant_id", tenantId).eq("user_id", user.id).maybeSingle();
  if (membershipError) throw membershipError;
  if (membership?.role !== "tenant_admin") {
    throw new WhatsAppError("Solo el administrador de esta empresa puede conectar WhatsApp", 403);
  }
  return admin;
}

export async function accountToken(
  admin: SupabaseClient, tenantId: string, phoneNumberId: string,
) {
  const { data: account, error } = await admin.from("whatsapp_accounts")
    .select("access_token, onboarding_mode").eq("tenant_id", tenantId)
    .eq("phone_number_id", phoneNumberId).maybeSingle();
  if (error) throw error;
  const token = account?.access_token ||
    (account?.onboarding_mode !== "coexistence" ? Deno.env.get("WHATSAPP_ACCESS_TOKEN") : null);
  if (!token) throw new WhatsAppError("No hay credenciales de WhatsApp para esta empresa", 409);
  return token;
}
