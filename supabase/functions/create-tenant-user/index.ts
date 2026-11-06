import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  parseTenantUser,
  provisionTenantUser,
  TenantUserCreationError,
} from "../_shared/tenant_user_creation.ts";

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
    if (!url || !serviceKey || !anonKey) {
      throw new Error("Supabase function secrets are not configured");
    }
    const authorization = request.headers.get("Authorization");
    if (!authorization) return json({ error: "Inicia sesión para continuar." }, 401);
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user) return json({ error: "La sesión no es válida." }, 401);
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: "La solicitud debe contener JSON válido." }, 400);
    }
    const input = parseTenantUser(body);
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const id = await provisionTenantUser(input, {
      authorize: async () => {
        const { data: role, error } = await caller.rpc("current_tenant_role", {
          p_tenant_id: input.tenantId,
        });
        if (error) throw error;
        // Creating accounts is limited to the company's own active admins.
        const { data: membership, error: membershipError } = await caller
          .from("tenant_memberships").select("role, is_active")
          .eq("tenant_id", input.tenantId).eq("user_id", user.id).maybeSingle();
        if (membershipError) throw membershipError;
        return role === "tenant_admin" && membership?.role === "tenant_admin" &&
          membership.is_active === true;
      },
      createIdentity: async (newUser) => {
        const { data, error } = await admin.auth.admin.createUser({
          email: newUser.email,
          password: newUser.password,
          email_confirm: true,
          user_metadata: { full_name: newUser.fullName, must_set_password: true },
          app_metadata: {
            must_set_password: true,
            tenant_creation_actor: user.id,
            tenant_creation_id: newUser.tenantId,
          },
        });
        if (error) {
          if (error.code === "email_exists" || error.code === "user_already_exists") {
            throw new TenantUserCreationError(
              "Ese correo ya tiene una cuenta en ITONE. No se agregó ni se modificó su acceso.", 409,
            );
          }
          if (error.status === 422 || error.status === 400) {
            throw new TenantUserCreationError(error.message, 400);
          }
          throw error;
        }
        if (!data.user) throw new Error("Auth returned no created user");
        return data.user.id;
      },
      finish: async (userId, newUser) => {
        const { error } = await admin.rpc("finish_tenant_user_creation", {
          p_actor_id: user.id, p_tenant_id: newUser.tenantId,
          p_user_id: userId, p_full_name: newUser.fullName, p_role: newUser.role,
        });
        if (error) throw error;
      },
      removeIdentity: async (userId) => {
        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error) throw error;
      },
    });
    return json({ user_id: id }, 201);
  } catch (error) {
    if (error instanceof TenantUserCreationError) {
      return json({ error: error.message }, error.status);
    }
    console.error("Tenant user creation failed", error);
    return json({
      error: "No fue posible crear el usuario. Actualiza la lista y verifica tu acceso o contacta al administrador.",
    }, 500);
  }
});
