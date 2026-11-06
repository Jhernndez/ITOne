import assert from "node:assert/strict";
import {
  parseTenantUser,
  provisionTenantUser,
  TenantUserCreationError,
} from "./tenant_user_creation.ts";

const body = {
  tenant_id: "10000000-0000-0000-0000-000000000001",
  full_name: " Agente Uno ",
  email: " AGENT@EXAMPLE.TEST ",
  role: "operator",
  password: "Temporary-Test123!",
};

Deno.test("validates and normalizes new tenant users without trimming passwords", () => {
  const parsed = parseTenantUser(body);
  assert.equal(parsed.fullName, "Agente Uno");
  assert.equal(parsed.email, "agent@example.test");
  assert.equal(parsed.role, "operator");
  assert.equal(parsed.password, body.password);
  for (const invalid of [
    null, [], {}, { ...body, tenant_id: "not-a-uuid" },
    { ...body, full_name: " " }, { ...body, full_name: "x".repeat(121) },
    { ...body, email: "invalid" }, { ...body, role: "platform_owner" },
    { ...body, password: "Short1" }, { ...body, password: "lowercase12345" },
    { ...body, password: "UPPERCASE12345" }, { ...body, password: "NoNumberPassword" },
    { ...body, password: "aA1".repeat(44) },
  ]) {
    assert.throws(() => parseTenantUser(invalid), TenantUserCreationError);
  }
});

Deno.test("denies non-admin callers before creating any identity", async () => {
  await assert.rejects(provisionTenantUser(parseTenantUser(body), {
    authorize: async () => false,
    createIdentity: () => { throw new Error("must not create"); },
    finish: () => { throw new Error("must not finish"); },
    removeIdentity: () => { throw new Error("must not delete"); },
  }), /administrador activo/);
});

Deno.test("existing email does not add membership or delete an existing account", async () => {
  await assert.rejects(provisionTenantUser(parseTenantUser(body), {
    authorize: async () => true,
    createIdentity: () => Promise.reject(new TenantUserCreationError("Correo existente", 409)),
    finish: () => { throw new Error("must not finish"); },
    removeIdentity: () => { throw new Error("must not delete"); },
  }), /Correo existente/);
});

Deno.test("creation provisions only the new account and the requested company and role", async () => {
  const events: string[] = [];
  const input = parseTenantUser(body);
  const id = await provisionTenantUser(input, {
    authorize: async () => { events.push("authorize"); return true; },
    createIdentity: async (created) => {
      assert.deepEqual(created, input);
      events.push("create"); return "new-user";
    },
    finish: async (userId, created) => {
      assert.equal(userId, "new-user"); assert.deepEqual(created, input);
      events.push("finish");
    },
    removeIdentity: () => { throw new Error("must not delete"); },
  });
  assert.equal(id, "new-user");
  assert.deepEqual(events, ["authorize", "create", "finish"]);
});

Deno.test("failed membership creation rolls back only the freshly created identity", async () => {
  let removed = "";
  await assert.rejects(provisionTenantUser(parseTenantUser(body), {
    authorize: async () => true,
    createIdentity: async () => "new-user",
    finish: () => Promise.reject(new Error("Actor no longer administrator")),
    removeIdentity: async (id) => { removed = id; },
  }), /no longer administrator/);
  assert.equal(removed, "new-user");
});

Deno.test("failed rollback explicitly requires platform intervention", async () => {
  await assert.rejects(provisionTenantUser(parseTenantUser(body), {
    authorize: async () => true,
    createIdentity: async () => "new-user",
    finish: () => Promise.reject(new Error("Membership failure")),
    removeIdentity: () => Promise.reject(new Error("Delete failure")),
  }), /cuenta pendiente/);
});
