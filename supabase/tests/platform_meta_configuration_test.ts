import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("server company reads and encrypted Meta overrides remain service-only and preserve unchanged secrets", async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role bypassrls;
      create schema vault;
      create table tenants(id uuid primary key,name text,private_field text);
      insert into tenants values(gen_random_uuid(),'Empresa','not-needed');
      create table vault.secrets(id uuid primary key default gen_random_uuid(),secret text);
      create view vault.decrypted_secrets as select id,secret as decrypted_secret from vault.secrets;
      create function vault.create_secret(s text) returns uuid language plpgsql as $$
      declare created uuid; begin insert into vault.secrets(secret) values(s) returning id into created; return created; end $$;
      create function vault.update_secret(i uuid,s text) returns void language sql as
        'update vault.secrets set secret=s where id=i';
      grant usage on schema public to service_role,authenticated,anon;
    `);
    const read = () =>
      db.query<{ config: Record<string, unknown> | null }>(
        "select read_platform_meta_configuration() as config",
      );
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../migrations/20261125195500_platform_meta_configuration.sql",
          import.meta.url,
        ),
      ),
    );
    await db.exec("set role authenticated");
    await assert.rejects(read(), /permission denied/);
    await assert.rejects(
      db.query("select * from platform_meta_configuration"),
      /permission denied/,
    );
    await assert.rejects(
      db.query(
        "select write_platform_meta_configuration('123456','987654','secret-not-visible',null)",
      ),
      /permission denied/,
    );
    await db.exec("set role service_role");
    assert.equal((await read()).rows[0].config, null);
    assert.equal(
      (await db.query("select id,name from tenants")).rows.length,
      1,
    );
    await assert.rejects(
      db.query("select private_field from tenants"),
      /permission denied/,
    );
    await db.query(
      "select write_platform_meta_configuration('123456','987654','secret-not-visible','webhook-not-visible')",
    );
    const saved = (await read()).rows[0].config!;
    assert.equal(saved.app_secret, "secret-not-visible");
    assert.equal(saved.verify_token, "webhook-not-visible");
    await db.query(
      "select write_platform_meta_configuration('123456','111111',null,null)",
    );
    const updated = (await read()).rows[0].config!;
    assert.equal(updated.config_id, "111111");
    assert.equal(updated.app_secret, "secret-not-visible");
    assert.equal(updated.verify_token, "webhook-not-visible");
    await assert.rejects(
      db.query(
        "select write_platform_meta_configuration('222222','111111',null,null)",
      ),
      /App Secret/,
    );
    await db.query(
      "select write_platform_meta_configuration('222222','111111','new-secret-not-visible',null)",
    );
    assert.equal(
      (await read()).rows[0].config!.app_secret,
      "new-secret-not-visible",
    );
  } finally {
    await db.close();
  }
});
