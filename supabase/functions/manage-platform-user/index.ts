import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://itone.itdata.com.co",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !serviceKey || !anonKey) {
      throw new Error("Supabase function secrets are not configured");
    }

    const authorization = request.headers.get("Authorization");
    if (!authorization) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }
    const token = authorization.replace(/^Bearer\s+/i, "").trim();
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: { user }, error: userError } =
      await caller.auth.getUser(token);
    if (userError || !user) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const { data: owner, error: ownerError } = await caller
      .from("platform_memberships")
      .select("role")
      .eq("user_id", user.id)
      .in("role", ["platform_owner", "platform_admin"])
      .maybeSingle();
    if (ownerError || !owner) {
      return new Response("Platform administrator access required", {
        status: 403,
        headers: corsHeaders,
      });
    }

    const body = await request.json();
    const targetUserId = String(body.user_id ?? "");
    if (!targetUserId || targetUserId === user.id) {
      throw new Error("Invalid target user");
    }
    const admin = createClient(url, serviceKey);
    const action = body.action;

    if (action === "reset_password") {
      const { data: target, error: targetError } =
        await admin.auth.admin.getUserById(targetUserId);
      if (targetError || !target.user?.email) throw targetError ??
        new Error("User email not found");
      const { error } = await admin.auth.admin.generateLink({
        type: "recovery",
        email: target.user.email,
        options: { redirectTo: "https://itone.itdata.com.co" },
      });
      if (error) throw error;
    } else if (action === "disable") {
      const { error } = await admin.auth.admin.updateUserById(targetUserId, {
        ban_duration: "876000h",
      });
      if (error) throw error;
    } else if (action === "enable") {
      const { error } = await admin.auth.admin.updateUserById(targetUserId, {
        ban_duration: "none",
      });
      if (error) throw error;
    } else if (action === "delete_user") {
      const { error } = await admin.auth.admin.deleteUser(targetUserId);
      if (error) throw error;
    } else {
      throw new Error("Unsupported user action");
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
