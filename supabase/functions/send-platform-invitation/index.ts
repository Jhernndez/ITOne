import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("Supabase function secrets are not configured");
    }

    const authorization = request.headers.get("Authorization");
    if (!authorization) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey);
    const accessToken = authorization.replace(/^Bearer\s+/i, "").trim();
    if (!accessToken) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!anonKey) {
      throw new Error("Supabase anonymous key is not configured");
    }
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });
    const { data: { user }, error: userError } =
      await userClient.auth.getUser(accessToken);
    if (userError) {
      console.error("Unable to validate invitation caller", userError);
    }
    if (!user) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const body = await request.json();
    const { data: invitationId, error: invitationError } =
      await userClient.rpc("create_platform_invitation", {
        p_email: String(body.email).trim().toLowerCase(),
        p_platform_role: body.platform_role,
        p_tenant_id: body.tenant_id ?? null,
        p_tenant_role: body.tenant_role ?? null,
      });
    if (invitationError) throw invitationError;
    const invitation = {
      id: invitationId as string,
      email: String(body.email).trim().toLowerCase(),
    };

    const { error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
      invitation.email,
      {
        data: {
          platform_invitation_id: invitation.id,
          must_set_password: true,
        },
        redirectTo: `${supabaseUrl}/auth/v1/callback`,
      },
    );
    if (inviteError) throw inviteError;

    return new Response(JSON.stringify({ id: invitation.id }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
