import { requireTenantAdmin, WhatsAppError } from "../_shared/whatsapp.ts";
import { ReviewError, reviewHandler } from "../_shared/whatsapp_review.ts";

Deno.serve(reviewHandler({
  env: (name) => Deno.env.get(name),
  fetch,
  authorize: async (request, tenantId) => {
    try {
      await requireTenantAdmin(request, tenantId);
    } catch (error) {
      if (error instanceof WhatsAppError) {
        throw new ReviewError(error.message, error.status);
      }
      throw error;
    }
  },
  reserve: async (tenantId) => {
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { error } = await admin.rpc("reserve_whatsapp_review_send", {
      p_tenant_id: tenantId,
    });
    if (error?.code === "P0001") throw new ReviewError(error.message, 429);
    if (error) throw error;
  },
}));
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
