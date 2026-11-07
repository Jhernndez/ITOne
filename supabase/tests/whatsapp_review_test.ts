import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("review attempt reservation is service only, tenant serialized and bounded", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create table public.tenants(id uuid primary key);
      insert into tenants values('${tenant}'),('${other}');
      alter default privileges in schema public grant all on tables to authenticated,anon;
    `);
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../migrations/20261106201500_whatsapp_review_attempts.sql",
          import.meta.url,
        ),
      ),
    );
    await db.exec("set role authenticated");
    await assert.rejects(
      db.query("select reserve_whatsapp_review_send($1)", [tenant]),
      /permission denied/,
    );
    await assert.rejects(
      db.query("select * from whatsapp_review_attempts"),
      /permission denied/,
    );
    await db.exec("reset role; set role service_role");
    await db.query("select reserve_whatsapp_review_send($1)", [tenant]);
    await assert.rejects(
      db.query("select reserve_whatsapp_review_send($1)", [tenant]),
      /un minuto/,
    );
    await db.query("select reserve_whatsapp_review_send($1)", [other]);
    await db.exec("reset role");
    await db.query(
      "update whatsapp_review_attempts set created_at=now()-interval '2 minutes' where tenant_id=$1",
      [tenant],
    );
    await db.query(
      `insert into whatsapp_review_attempts(tenant_id,created_at)
      select $1,now()-interval '2 minutes' from generate_series(1,19)`,
      [tenant],
    );
    await db.exec("set role service_role");
    await assert.rejects(
      db.query("select reserve_whatsapp_review_send($1)", [tenant]),
      /20 intentos/,
    );
    await db.exec("reset role");
    await db.query(
      "update whatsapp_review_attempts set created_at=now()-interval '25 hours' where tenant_id=$1",
      [tenant],
    );
    await db.exec("set role service_role");
    await db.query("select reserve_whatsapp_review_send($1)", [tenant]);
  } finally {
    await db.close();
  }
});
