const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const verifyToken = Deno.env.get("WHATSAPP_VERIFY_TOKEN");

Deno.serve(async (request) => {
  try {
    if (request.method === "GET") {
      const url = new URL(request.url);
      const mode = url.searchParams.get("hub.mode");
      const token = url.searchParams.get("hub.verify_token");
      const challenge = url.searchParams.get("hub.challenge");

      if (
        mode === "subscribe" &&
        verifyToken &&
        token === verifyToken &&
        challenge
      ) {
        return new Response(challenge, { status: 200 });
      }

      return new Response("Webhook verification failed", { status: 403 });
    }

    if (request.method === "POST") {
      const payload = await request.json();
      console.log("WhatsApp webhook event received", payload);
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response("Method not allowed", {
      status: 405,
      headers: corsHeaders,
    });
  } catch (error) {
    console.error("WhatsApp webhook error", error);
    return new Response(JSON.stringify({ error: "Invalid webhook request" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
