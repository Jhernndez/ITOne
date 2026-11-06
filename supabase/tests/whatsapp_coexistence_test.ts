import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

const db = new PGlite();
const tenant = "00000000-0000-0000-0000-000000000001";
const otherTenant = "00000000-0000-0000-0000-000000000002";
const user = "00000000-0000-0000-0000-000000000003";
const migrations = new URL("../migrations/", import.meta.url);

Deno.test("coexistence migration, tenant isolation, idempotency and out-of-order history", async () => {
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql as 'select null::uuid';
      create table public.tenants(id uuid primary key);
      create table public.tenant_memberships(tenant_id uuid, user_id uuid, role text);
      create publication supabase_realtime;
      insert into tenants values ('${tenant}'), ('${otherTenant}');
      insert into auth.users values ('${user}');
      insert into tenant_memberships values ('${tenant}', '${user}', 'tenant_admin');
    `);
    for (const file of [
      "20260923200000_whatsapp_inbox.sql",
      "20260923201500_whatsapp_webhook_permissions.sql",
      "20260923231500_tenant_integrations.sql",
      "20260923232000_protect_whatsapp_tokens.sql",
      "20260924153000_whatsapp_realtime_status.sql",
    ]) {
      await db.exec(await Deno.readTextFile(new URL(file, migrations)));
    }
    const notifications = await Deno.readTextFile(new URL("20260924193000_notifications_and_api_integrations.sql", migrations));
    await db.exec(notifications.split("create table if not exists public.tenant_notification_settings")[0]);
    await db.exec(await Deno.readTextFile(new URL("20261106123000_whatsapp_coexistence.sql", migrations)));
    const connected = await db.query<{ id: string }>(
      "select connect_whatsapp_coexistence($1,$2,$3,$4,$5,$6) as id",
      [tenant, "123", "456", "test-token-not-a-credential", "573000000000", "Empresa"],
    );
    const id = connected.rows[0].id;
    await assert.rejects(db.query("select connect_whatsapp_coexistence($1,$2,$3,$4,$5,$6)",
      [otherTenant, "123", "456", "test-token", "", "Otra"]), /another tenant/);

    const message = (providerId: string, timestamp: string, source = "cloud_api") => ({
      provider_message_id: providerId, phone_number: "573110000000", user_id: "US.test",
      direction: "inbound", message_type: "text", body: providerId, timestamp,
      delivery_status: "accepted", source,
    });
    const ingest = async (messages: unknown[]) => await db.query(
      "select ingest_whatsapp_messages($1,$2::jsonb)", [id, JSON.stringify(messages)],
    );
    await ingest([message("live", "2026-11-06T12:00:00Z")]);
    await ingest([message("live", "2026-11-06T12:00:00Z")]);
    await ingest([message("old", "2026-06-06T12:00:00Z", "history")]);
    const counts = await db.query<{ messages: number; notifications: number }>(
      "select (select count(*)::int from whatsapp_messages) as messages, (select count(*)::int from notifications) as notifications",
    );
    assert.deepEqual(counts.rows[0], { messages: 2, notifications: 1 });
    const conversation = await db.query<{ last_message_at: Date; status: string }>(
      "select last_message_at, status from whatsapp_conversations",
    );
    assert.equal(new Date(conversation.rows[0].last_message_at).toISOString(), "2026-11-06T12:00:00.000Z");
    assert.equal(conversation.rows[0].status, "open");

    await ingest([{
      ...message("echo", "2026-11-06T12:01:00Z", "business_app"),
      direction: "outbound", body: "Celular",
    }]);
    await ingest([{
      ...message("edit", "2026-11-06T12:02:00Z", "business_app"),
      direction: "outbound", message_type: "edit", body: "Editado", original_message_id: "echo",
    }]);
    await ingest([{
      ...message("older-edit", "2026-11-06T12:01:30Z", "business_app"),
      direction: "outbound", message_type: "edit", body: "Viejo", original_message_id: "echo",
    }]);
    const edited = await db.query<{ body: string }>("select body from whatsapp_messages where provider_message_id='echo'");
    assert.equal(edited.rows[0].body, "Editado");

    await ingest([{
      ...message("bsuid", "2026-11-06T12:03:00Z", "business_app"),
      phone_number: null, user_id: "US.no-phone", direction: "outbound",
    }]);
    const scopedContact = await db.query<{ count: number }>(
      "select count(*)::int as count from whatsapp_contacts where whatsapp_user_id='US.no-phone' and phone_number is null",
    );
    assert.equal(scopedContact.rows[0].count, 1);

    await db.query("select update_whatsapp_history_progress($1,100,null,false)", [id]);
    await db.query("select update_whatsapp_history_progress($1,20,null,false)", [id]);
    const progress = await db.query<{ history_sync_status: string; history_sync_progress: number }>(
      "select history_sync_status, history_sync_progress from whatsapp_accounts where id=$1", [id],
    );
    assert.deepEqual(progress.rows[0], { history_sync_status: "complete", history_sync_progress: 100 });
    const privileges = await db.query<{ token: boolean; rpc: boolean }>(`
      select has_column_privilege('authenticated','whatsapp_accounts','access_token','SELECT') as token,
        has_function_privilege('authenticated','ingest_whatsapp_messages(uuid,jsonb)','EXECUTE') as rpc
    `);
    assert.deepEqual(privileges.rows[0], { token: false, rpc: false });

    const history = Array.from({ length: 2000 }, (_, index) =>
      message(`history-${index}`, "2026-07-01T12:00:00Z", "history"));
    for (let offset = 0; offset < history.length; offset += 200) {
      await ingest(history.slice(offset, offset + 200));
    }
    const historyCount = await db.query<{ count: number }>(
      "select count(*)::int as count from whatsapp_messages where source='history'",
    );
    assert.equal(historyCount.rows[0].count, 2001);
  } finally {
    await db.close();
  }
});
