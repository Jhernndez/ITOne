import {
  graphVersion,
  requireTenantAdmin,
  WhatsAppError,
} from "../_shared/whatsapp.ts";
import {
  TemplateError,
  templatesHandler,
} from "../_shared/whatsapp_templates.ts";

Deno.serve(templatesHandler({
  version: graphVersion(),
  fetch,
  authorize: async (request, tenant) => {
    let admin;
    try {
      admin = await requireTenantAdmin(request, tenant);
    } catch (error) {
      if (error instanceof WhatsAppError) {
        throw new TemplateError(error.message, error.status);
      }
      throw error;
    }
    const { data, error } = await admin.from("whatsapp_accounts")
      .select("id,business_account_id,access_token,name").eq(
        "tenant_id",
        tenant,
      );
    if (error) throw error;
    return data ?? [];
  },
}));
