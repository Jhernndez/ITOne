export class TenantUserCreationError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export interface NewTenantUser {
  tenantId: string;
  fullName: string;
  email: string;
  role: "tenant_admin" | "supervisor" | "operator";
  password: string;
}

export function parseTenantUser(input: unknown): NewTenantUser {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new TenantUserCreationError("Solicitud no válida.", 400);
  }
  const body = input as Record<string, unknown>;
  const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (typeof body.tenant_id !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.tenant_id)) {
    throw new TenantUserCreationError("Empresa no válida.", 400);
  }
  if (fullName.length < 1 || fullName.length > 120) {
    throw new TenantUserCreationError("El nombre debe tener entre 1 y 120 caracteres.", 400);
  }
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new TenantUserCreationError("Ingresa un correo válido.", 400);
  }
  if (body.role !== "tenant_admin" && body.role !== "supervisor" && body.role !== "operator") {
    throw new TenantUserCreationError("Rol no válido.", 400);
  }
  if (password.length < 12 || password.length > 128 ||
    !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/[0-9]/.test(password)) {
    throw new TenantUserCreationError(
      "La contraseña temporal debe tener entre 12 y 128 caracteres, mayúscula, minúscula y número.", 400,
    );
  }
  return { tenantId: body.tenant_id, fullName, email, password, role: body.role };
}

export async function provisionTenantUser(
  input: NewTenantUser,
  actions: {
    authorize: () => Promise<boolean>;
    createIdentity: (input: NewTenantUser) => Promise<string>;
    finish: (userId: string, input: NewTenantUser) => Promise<void>;
    removeIdentity: (userId: string) => Promise<void>;
  },
): Promise<string> {
  if (!await actions.authorize()) {
    throw new TenantUserCreationError(
      "Solo un administrador activo de esta empresa puede crear usuarios.", 403,
    );
  }
  const userId = await actions.createIdentity(input);
  try {
    await actions.finish(userId, input);
  } catch (error) {
    try {
      await actions.removeIdentity(userId);
    } catch (cleanupError) {
      console.error("Tenant user provisioning rollback failed", { userId, cleanupError });
      throw new TenantUserCreationError(
        "No se pudo completar la creación ni retirar la cuenta pendiente. Contacta al administrador de plataforma antes de reintentar.",
        500,
      );
    }
    throw error;
  }
  return userId;
}
