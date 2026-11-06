import assert from "node:assert/strict";
import { parseTenantAccount } from "./tenant_user_account.ts";
import { TenantUserCreationError } from "./tenant_user_creation.ts";

const body = {
  tenant_id: "10000000-0000-0000-0000-000000000001",
  user_id: "10000000-0000-0000-0000-000000000002",
  full_name: " Nuevo Nombre ",
  expected_name: "Anterior",
};

Deno.test("account edits preserve absent password and validate strong bcrypt byte limits", () => {
  assert.equal(parseTenantAccount(body).fullName, "Nuevo Nombre");
  assert.equal(parseTenantAccount(body).password, null);
  assert.equal(parseTenantAccount({ ...body, password: "" }).password, null);
  assert.equal(parseTenantAccount({ ...body, password: null }).password, null);
  const valid = "Aa1" + "x".repeat(69);
  assert.equal(parseTenantAccount({ ...body, password: valid }).password, valid);
  for (const invalid of [
    null, [], {}, { ...body, tenant_id: "invalid" }, { ...body, user_id: "invalid" },
    { ...body, full_name: " " }, { ...body, full_name: "x".repeat(121) },
    { ...body, expected_name: null }, { ...body, password: 123 },
    { ...body, password: "Aa1" }, { ...body, password: "a".repeat(12) },
    { ...body, password: "Aa1" + "x".repeat(70) },
    { ...body, password: "Aa1" + "é".repeat(35) },
  ]) {
    assert.throws(() => parseTenantAccount(invalid), TenantUserCreationError);
  }
});
