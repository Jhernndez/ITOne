import assert from "node:assert/strict";
import { PGlite } from "npm:@electric-sql/pglite";

Deno.test("external API migration preserves secrets and enforces tenant grants and automation opt-ins", async () => {
  const db = new PGlite();
  const tenant = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  const integration = "20000000-0000-0000-0000-000000000001";
  const otherIntegration = "20000000-0000-0000-0000-000000000002";
  const resource = "30000000-0000-0000-0000-000000000001";
  const otherResource = "30000000-0000-0000-0000-000000000002";
  const query = (sql: string, values: unknown[] = []) =>
    db.query<Record<string, unknown>>(sql, values);
  const login = async (tenantId: string, role = "tenant_admin") => {
    await db.exec("reset role");
    await query("select set_config('test.tenant',$1,false)", [tenantId]);
    await query("select set_config('test.role',$1,false)", [role]);
    await db.exec("set role authenticated");
  };
  try {
    await db.exec(`
      create role anon;
      create role authenticated;
      create role service_role bypassrls;
      grant usage on schema public to authenticated, anon, service_role;
      create function public.current_tenant_role(t uuid) returns text
        language sql stable as $$
          select case when t = nullif(current_setting('test.tenant', true),'')::uuid
            then nullif(current_setting('test.role', true),'') else null end
        $$;
      create table public.tenant_api_integrations(
        id uuid primary key default gen_random_uuid(), tenant_id uuid not null,
        name text not null, base_url text not null, auth_type text not null,
        auth_config jsonb not null default '{}', enabled boolean not null default true,
        created_at timestamptz not null default now(), updated_at timestamptz not null default now()
      );
      create table public.tenant_api_resources(
        id uuid primary key default gen_random_uuid(), tenant_id uuid not null,
        integration_id uuid not null references public.tenant_api_integrations(id) on delete cascade,
        name text not null, path text not null, http_method text not null default 'GET',
        enabled boolean not null default true,
        created_at timestamptz not null default now(), updated_at timestamptz not null default now()
      );
      alter table public.tenant_api_integrations enable row level security;
      alter table public.tenant_api_resources enable row level security;
      grant select,insert,update,delete on public.tenant_api_integrations,public.tenant_api_resources
        to authenticated,service_role;
      -- Reproduce the old ineffective column revoke under a table grant.
      revoke select(auth_config),insert(auth_config),update(auth_config)
        on public.tenant_api_integrations from authenticated;
      create policy "tenant members can view api integrations" on public.tenant_api_integrations
        for select to authenticated using (true);
      create policy "tenant admins can manage api integrations" on public.tenant_api_integrations
        for all to authenticated using (true) with check (true);
      create policy "tenant members can view api resources" on public.tenant_api_resources
        for select to authenticated using (true);
      create policy "tenant admins can manage api resources" on public.tenant_api_resources
        for all to authenticated using (true) with check (true);
      insert into public.tenant_api_integrations(id,tenant_id,name,base_url,auth_type,auth_config) values
        ('${integration}','${tenant}','Orders','https://orders.example.com','bearer_token','{"token":"existing-secret"}'),
        ('${otherIntegration}','${other}','Other','https://other.example.com','api_key','{"header_name":"X-Key","header_value":"other-secret"}');
      insert into public.tenant_api_resources(id,tenant_id,integration_id,name,path,http_method) values
        ('${resource}','${tenant}','${integration}','Create','/orders','POST'),
        ('${otherResource}','${other}','${otherIntegration}','List','/orders','GET');
    `);
    const beforeIntegrations =
      (await query("select * from tenant_api_integrations order by id")).rows;
    const beforeResources =
      (await query("select * from tenant_api_resources order by id")).rows;
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../migrations/20261106210000_external_api_security.sql",
          import.meta.url,
        ),
      ),
    );
    assert.deepEqual(
      (await query("select * from tenant_api_integrations order by id")).rows,
      beforeIntegrations,
    );
    const migrated =
      (await query("select * from tenant_api_resources order by id")).rows;
    assert.deepEqual(
      migrated.map(
        ({ enabled_for_automation, allow_automation_writes, ...row }) => {
          assert.equal(enabled_for_automation, false);
          assert.equal(allow_automation_writes, false);
          return row;
        },
      ),
      beforeResources,
    );
    assert.deepEqual(
      (await query(
        `select column_name,is_nullable,column_default from information_schema.columns
        where table_schema='public' and table_name='tenant_api_resources'
          and column_name in ('enabled_for_automation','allow_automation_writes')
        order by column_name`,
      )).rows,
      [
        {
          column_name: "allow_automation_writes",
          is_nullable: "NO",
          column_default: "false",
        },
        {
          column_name: "enabled_for_automation",
          is_nullable: "NO",
          column_default: "false",
        },
      ],
    );

    await login(tenant);
    assert.equal(
      (await query(
        "select id,name,base_url,auth_type,enabled from tenant_api_integrations",
      )).rows.length,
      1,
    );
    assert.equal(
      (await query(
        "select id from tenant_api_integrations where tenant_id=$1",
        [other],
      )).rows.length,
      0,
    );
    await assert.rejects(
      query("select auth_config from tenant_api_integrations"),
      /permission denied/,
    );
    await assert.rejects(
      query("select * from tenant_api_integrations"),
      /permission denied/,
    );
    await assert.rejects(
      query("update tenant_api_integrations set auth_config='{}' where id=$1", [
        integration,
      ]),
      /permission denied/,
    );
    await assert.rejects(
      query("update tenant_api_integrations set name='changed' where id=$1", [
        integration,
      ]),
      /permission denied/,
    );
    await assert.rejects(
      query(
        `insert into tenant_api_integrations(tenant_id,name,base_url,auth_type,auth_config)
      values($1,'Bad','https://example.com','none','{}')`,
        [tenant],
      ),
      /permission denied/,
    );

    const created = (await query(
      `insert into tenant_api_resources(tenant_id,integration_id,name,path)
      values($1,$2,'New','/new') returning *`,
      [tenant, integration],
    )).rows[0];
    assert.equal(created.enabled_for_automation, false);
    assert.equal(created.allow_automation_writes, false);
    await query(
      `update tenant_api_resources set enabled_for_automation=true,allow_automation_writes=true
      where id=$1`,
      [resource],
    );
    assert.deepEqual(
      (await query(
        `select enabled_for_automation,allow_automation_writes
      from tenant_api_resources where id=$1`,
        [resource],
      )).rows[0],
      { enabled_for_automation: true, allow_automation_writes: true },
    );
    await assert.rejects(
      query(
        `insert into tenant_api_resources(tenant_id,integration_id,name,path)
      values($1,$2,'Cross','/cross')`,
        [tenant, otherIntegration],
      ),
      /row-level security/,
    );
    await assert.rejects(
      query("update tenant_api_resources set integration_id=$1 where id=$2", [
        otherIntegration,
        resource,
      ]),
      /row-level security/,
    );
    await assert.rejects(
      query("update tenant_api_resources set tenant_id=$1 where id=$2", [
        other,
        resource,
      ]),
      /row-level security/,
    );
    await assert.rejects(
      query(
        `insert into tenant_api_resources(tenant_id,integration_id,name,path)
      values($1,$2,'Cross','/cross')`,
        [other, integration],
      ),
      /row-level security/,
    );
    assert.equal(
      (await query("select id from tenant_api_resources where id=$1", [
        otherResource,
      ])).rows.length,
      0,
    );
    assert.equal(
      (await query(
        "delete from tenant_api_integrations where id=$1 returning id",
        [otherIntegration],
      )).rows.length,
      0,
    );

    await login(tenant, "operator");
    assert.equal(
      (await query("select id,name from tenant_api_integrations")).rows.length,
      1,
    );
    assert.equal(
      (await query(
        "update tenant_api_resources set allow_automation_writes=true where id=$1 returning id",
        [resource],
      )).rows.length,
      0,
    );
    await assert.rejects(
      query(
        `insert into tenant_api_resources(tenant_id,integration_id,name,path)
      values($1,$2,'Operator','/no')`,
        [tenant, integration],
      ),
      /row-level security/,
    );
    await assert.rejects(
      query("select auth_config from tenant_api_integrations"),
      /permission denied/,
    );
    await assert.rejects(
      query("update tenant_api_integrations set auth_config='{}'"),
      /permission denied/,
    );
    assert.equal(
      (await query(
        "delete from tenant_api_integrations where id=$1 returning id",
        [integration],
      )).rows.length,
      0,
    );

    await login(other);
    assert.equal(
      (await query("select id from tenant_api_integrations")).rows[0].id,
      otherIntegration,
    );
    assert.equal(
      (await query("select id from tenant_api_resources")).rows[0].id,
      otherResource,
    );
    await db.exec("reset role; set role anon");
    await assert.rejects(
      query("select id from tenant_api_integrations"),
      /permission denied/,
    );
    await db.exec("reset role; set role service_role");
    assert.deepEqual(
      (await query(
        "select auth_config from tenant_api_integrations where id=$1",
        [integration],
      )).rows[0].auth_config,
      { token: "existing-secret" },
    );
    await db.exec("reset role");
    assert.deepEqual(
      (await query("select * from tenant_api_integrations order by id")).rows,
      beforeIntegrations,
    );
  } finally {
    await db.close();
  }
});
