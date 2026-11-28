import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { executeFlow, type RuntimeGraph, type RuntimeState } from "../_shared/automation_runtime.ts";
import { executeExternalResource } from "../_shared/external_api.ts";
import { graphVersion, messageRecipient } from "../_shared/whatsapp.ts";

interface Job {
  id: string;
  tenant_id: string;
  account_id: string;
  conversation_id: string;
  message_id: string | null;
  lease: string;
}
function checked<T>(result: { data: T; error: unknown }): T {
  if (result.error) {
    if (result.error instanceof Error) throw result.error;
    if (typeof result.error === "object" && "message" in result.error && typeof result.error.message === "string") {
      throw new Error(result.error.message);
    }
    throw new Error("No se pudo persistir la ejecución del bot");
  }
  return result.data;
}
async function rpc(client: SupabaseClient, name: string, params: Record<string, unknown> = {}) {
  return checked(await client.rpc(name, params));
}
async function processJob(client: SupabaseClient, job: Job) {
  let effectStep: number | null = null;
  let effects = 0;
  const started = Date.now();
  try {
    await (async () => {
    const binding = checked(await client.from("whatsapp_bot_bindings").select("enabled,flow_id,version")
      .eq("tenant_id", job.tenant_id).eq("account_id", job.account_id).maybeSingle());
    if (!binding?.enabled) return;
    const previous = checked(await client.from("whatsapp_bot_sessions").select("*")
      .eq("tenant_id", job.tenant_id).eq("conversation_id", job.conversation_id).maybeSingle());
    if (previous?.status === "human" || previous?.status === "error") return;
    const account = checked(await client.from("whatsapp_accounts")
      .select("phone_number_id,access_token,onboarding_mode,status").eq("tenant_id", job.tenant_id).eq("id", job.account_id).single());
    if (!account || account.status !== "active" ||
        !["coexistence", "cloud_api"].includes(account.onboarding_mode) || !account.access_token) {
      throw new Error("La conexión de este número requiere atención");
    }
    const conversation = checked(await client.from("whatsapp_conversations").select("contact_id")
      .eq("tenant_id", job.tenant_id).eq("id", job.conversation_id).single());
    if (!conversation) throw new Error("Conversación no disponible");
    const contact = checked(await client.from("whatsapp_contacts").select("phone_number,whatsapp_user_id,whatsapp_account_id,display_name,profile_name")
      .eq("tenant_id", job.tenant_id).eq("id", conversation.contact_id).single());
    if (!contact || !(contact.phone_number ?? contact.whatsapp_user_id)) throw new Error("Contacto no disponible");
    const recipient = messageRecipient(contact, job.account_id);
    const inbound = job.message_id ? checked(await client.from("whatsapp_messages")
      .select("body,message_type,provider_timestamp,created_at").eq("id", job.message_id)
      .eq("tenant_id", job.tenant_id).eq("conversation_id", job.conversation_id).single()) : null;
    const latest = checked(await client.from("whatsapp_messages").select("provider_timestamp,created_at")
      .eq("tenant_id", job.tenant_id).eq("conversation_id", job.conversation_id)
      .eq("direction", "inbound").eq("source", "cloud_api").is("original_message_id", null)
      .order("created_at", { ascending: false }).limit(1).maybeSingle());
    const timestamp = latest?.provider_timestamp ?? latest?.created_at;
    if (!timestamp || Date.now() - Date.parse(timestamp) >= 24 * 60 * 60 * 1000) {
      throw new Error("La ventana de atención de WhatsApp expiró; usa una plantilla aprobada");
    }
    if (inbound && Date.now() - Date.parse(inbound.provider_timestamp ?? inbound.created_at) >= 24 * 60 * 60 * 1000) return;
    const active = previous && previous.status !== "completed" ? previous : binding;
    const version = checked(await client.from("automation_flow_versions").select("graph")
      .eq("tenant_id", job.tenant_id).eq("flow_id", active.flow_id).eq("version", active.version).single());
    if (!version) throw new Error("Versión publicada no disponible");
    const graph = version.graph as RuntimeGraph;
    const start = graph.nodes.find((n) => n.kind === "start");
    if (!start) throw new Error("El flujo no tiene un inicio");
    const state: RuntimeState = previous && previous.status !== "completed" ? {
      flow_id: previous.flow_id, version: previous.version, node_id: previous.node_id,
      variables: previous.variables, status: previous.status, steps: previous.steps,
    } : {
      flow_id: binding.flow_id, version: binding.version, node_id: start.id, variables: {},
      status: "running", steps: 0,
    };
    state.variables.contact_phone = contact.phone_number ?? contact.whatsapp_user_id;
    state.variables.contact_name = contact.display_name ?? contact.profile_name ?? "";
    if (inbound) state.variables.last_message = inbound.body ?? "";
    const save = async (s: RuntimeState) => {
      await rpc(client, "save_whatsapp_bot_session", { p_job_id: job.id, p_lease: job.lease, p_state: s });
    };
    if (inbound && inbound.message_type !== "text") {
      state.status = "human";
      await save(state);
      return;
    }
    const reserve = async (step: number, kind: string) => {
      if (++effects > 6 || Date.now() - started > 45000) {
        throw new Error("Demasiadas acciones consecutivas; agrega una pregunta o divide el flujo");
      }
      await rpc(client, "reserve_whatsapp_bot_effect", { p_job_id: job.id, p_lease: job.lease, p_step: step, p_kind: kind });
      effectStep = step;
    };
    const confirm = async (providerId: string | null = null) => {
      checked(await client.from("whatsapp_bot_effects").update({ status: "confirmed", provider_id: providerId })
        .eq("job_id", job.id).eq("step", effectStep));
      effectStep = null;
    };
    await executeFlow(graph, state, inbound?.body ?? null, {
      save,
      send: async (text, step) => {
        if (Date.now() - Date.parse(timestamp) >= 24 * 60 * 60 * 1000) {
          throw new Error("La ventana de atención de WhatsApp expiró");
        }
        await reserve(step, "message");
        const response = await fetch(
          `https://graph.facebook.com/${graphVersion()}/${encodeURIComponent(account.phone_number_id)}/messages`, {
            method: "POST",
            headers: { Authorization: `Bearer ${account.access_token}`, "Content-Type": "application/json" },
            body: JSON.stringify({ messaging_product: "whatsapp", ...recipient,
              type: "text", text: { body: text, preview_url: false } }),
            signal: AbortSignal.timeout(15000),
          },
        );
        const result = await response.json();
        if (!response.ok || result.error) {
          checked(await client.from("whatsapp_bot_effects").update({ status: "failed" }).eq("job_id", job.id).eq("step", step));
          effectStep = null;
          console.error("Bot message rejected", { job: job.id, status: response.status, code: result.error?.code });
          throw new Error(`WhatsApp rechazó el envío (${result.error?.code ?? response.status})`);
        }
        const providerId = result.messages?.[0]?.id;
        if (typeof providerId !== "string") throw new Error("WhatsApp no confirmó el envío; requiere revisión");
        checked(await client.from("whatsapp_messages").upsert({
          tenant_id: job.tenant_id, conversation_id: job.conversation_id, whatsapp_account_id: job.account_id,
          provider_message_id: providerId, direction: "outbound", message_type: "text", body: text,
          delivery_status: "accepted", source: "cloud_api", provider_timestamp: new Date().toISOString(),
        }, { onConflict: "whatsapp_account_id,provider_message_id", ignoreDuplicates: true }));
        checked(await client.from("whatsapp_conversations").update({
          last_message_at: new Date().toISOString(), updated_at: new Date().toISOString(),
        }).eq("id", job.conversation_id).eq("tenant_id", job.tenant_id));
        await confirm(providerId);
      },
      api: async (resourceId, query, body, step) => {
        await reserve(step, "api");
        const result = await executeExternalResource(client, {
          tenantId: job.tenant_id, resourceId, query, body,
          automation: true, idempotencyKey: `${job.id}:${step}`,
        });
        await confirm();
        return { ...result };
      },
    });
    })();
  } catch (error) {
    const message = error instanceof Error ? error.message : "Error al procesar la automatización";
    console.error("WhatsApp bot job failed", { id: job.id, message });
    if (effectStep !== null) checked(await client.from("whatsapp_bot_effects")
      .update({ status: "unknown" }).eq("job_id", job.id).eq("step", effectStep));
    await rpc(client, "finish_whatsapp_bot_job", { p_job_id: job.id, p_lease: job.lease, p_error: message.slice(0, 1000) });
    return;
  }
  await rpc(client, "finish_whatsapp_bot_job", { p_job_id: job.id, p_lease: job.lease });
}

export async function botWorker(request: Request) {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("WHATSAPP_BOT_WORKER_SECRET");
  if (!secret || request.headers.get("x-bot-secret") !== secret) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return new Response("Worker not configured", { status: 503 });
  const client = createClient(url, key);
  try {
    const started = Date.now();
    let processed = 0;
    while (processed < 20 && Date.now() - started < 45000) {
      const job = await rpc(client, "claim_whatsapp_bot_job") as Job | null;
      if (!job) break;
      await processJob(client, job);
      processed++;
    }
    return Response.json({ ok: true, processed });
  } catch (error) {
    console.error("Bot worker failed", error);
    return Response.json({ error: "Worker failure; pending work retained" }, { status: 500 });
  }
}
if (import.meta.main) Deno.serve(botWorker);
