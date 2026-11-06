import { TenantUserCreationError } from "./tenant_user_creation.ts";

export function parseTenantAccount(input: unknown) {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new TenantUserCreationError("Solicitud no válida.", 400);
  }
  const body = input as Record<string, unknown>;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (typeof body.tenant_id !== "string" || !uuid.test(body.tenant_id) ||
    typeof body.user_id !== "string" || !uuid.test(body.user_id)) {
    throw new TenantUserCreationError("Empresa o usuario no válido.", 400);
  }
  if (typeof body.full_name !== "string" ||
    body.full_name.trim().length < 1 || body.full_name.trim().length > 120 ||
    typeof body.expected_name !== "string") {
    throw new TenantUserCreationError("El nombre debe tener entre 1 y 120 caracteres.", 400);
  }
  let password: string | null = null;
  if (body.password !== undefined && body.password !== null && body.password !== "") {
    if (typeof body.password !== "string" || body.password.length < 12 ||
      new TextEncoder().encode(body.password).length > 72 ||
      !/[a-z]/.test(body.password) || !/[A-Z]/.test(body.password) || !/[0-9]/.test(body.password)) {
      throw new TenantUserCreationError(
        "La contraseña temporal requiere al menos 12 caracteres, mayúscula, minúscula y número, y un máximo de 72 bytes.", 400,
      );
    }
    password = body.password;
  }
  return {
    tenantId: body.tenant_id, userId: body.user_id,
    fullName: body.full_name.trim(), expectedName: body.expected_name, password,
  };
}
