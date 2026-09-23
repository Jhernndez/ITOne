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

    const { data: { user }, error: userError } =
      await adminClient.auth.getUser(accessToken);
    if (userError) {
      console.error("Unable to validate invitation caller", userError);
    }
    if (!user) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const { data: owner, error: ownerError } = await adminClient
      .from("platform_memberships")
      .select("role")
      .eq("user_id", user.id)
      .eq("role", "platform_owner")
      .maybeSingle();
    if (ownerError) {
      console.error("Unable to load platform membership", ownerError);
      throw new Error("Unable to verify platform membership");
    }
    if (!owner) {
      console.error("Invitation caller is not a platform owner", {
        userId: user.id,
        email: user.email,
      });
      return new Response("Platform owner access required", {
        status: 403,
        headers: corsHeaders,
      });
    }

    const body = await request.json();
    const { data: invitation, error: invitationError } = await adminClient
      .from("platform_invitations")
      .insert({
        email: String(body.email).trim().toLowerCase(),
        platform_role: body.platform_role,
        tenant_id: body.tenant_id ?? null,
        tenant_role: body.tenant_role ?? null,
        invited_by: user.id,
      })
      .select("id, email")
      .single();
    if (invitationError) throw invitationError;

    const { error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
      invitation.email,
      {
        data: { platform_invitation_id: invitation.id },
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
