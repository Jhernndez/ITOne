import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { WhatsAppError } from "./whatsapp.ts";

export async function requirePlatformOwner(request: Request) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  if (!url || !key) throw new WhatsAppError("Servidor no configurado.", 503);
  if (!authorization) throw new WhatsAppError("Authentication required", 401);
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user }, error } = await caller.auth.getUser();
  if (error || !user) throw new WhatsAppError("Authentication required", 401);
  const { data: disabled, error: disabledError } = await caller.rpc(
    "is_current_user_disabled",
  );
  if (disabledError) throw disabledError;
  if (disabled) throw new WhatsAppError("User access is disabled", 403);
  const { data: membership, error: membershipError } = await caller
    .from("platform_memberships").select("role").eq("user_id", user.id)
    .maybeSingle();
  if (membershipError) throw membershipError;
  if (membership?.role !== "platform_owner") {
    throw new WhatsAppError(
      "Solo el propietario de Platform puede consultar el diagnóstico de Meta.",
      403,
    );
  }
  return createClient(url, key);
}
