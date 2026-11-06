import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { hash } from "npm:bcryptjs@3.0.3";
import { parseTenantAccount } from "../_shared/tenant_user_account.ts";
import { TenantUserCreationError } from "../_shared/tenant_user_creation.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !serviceKey || !anonKey) throw new Error("Supabase secrets are not configured");
    const authorization = request.headers.get("Authorization");
    if (!authorization) return json({ error: "Inicia sesión para continuar." }, 401);
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user) return json({ error: "La sesión no es válida." }, 401);
    let body: unknown;
    try { body = await request.json(); } catch {
      return json({ error: "La solicitud debe contener JSON válido." }, 400);
    }
    const input = parseTenantAccount(body);
    const { data: role, error: roleError } = await caller.rpc("current_tenant_role", {
      p_tenant_id: input.tenantId,
    });
    if (roleError) throw roleError;
    if (role !== "tenant_admin" || user.id === input.userId) {
      return json({ error: "Se requiere otro administrador activo de la empresa." }, 403);
    }
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await admin.rpc("update_tenant_user_account", {
      p_actor_id: user.id, p_tenant_id: input.tenantId, p_user_id: input.userId,
      p_full_name: input.fullName, p_expected_name: input.expectedName,
      p_password_hash: input.password === null ? null : await hash(input.password, 12),
    });
    if (error) {
      if (error.code === "P0001") return json({ error: error.message }, 409);
      throw error;
    }
    return json({ ok: true }, 200);
  } catch (error) {
    if (error instanceof TenantUserCreationError) return json({ error: error.message }, error.status);
    console.error("Tenant account update failed", error);
    return json({ error: "No fue posible editar la cuenta. Actualiza la lista o contacta al administrador." }, 500);
  }
});
