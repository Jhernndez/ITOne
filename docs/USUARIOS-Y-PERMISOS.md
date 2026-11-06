# Usuarios y permisos por empresa

El módulo **Usuarios y permisos** está disponible para administradores de la
empresa. Consulta las membresías reales de Supabase: no crea usuarios de muestra.

## Alcance

- Búsqueda, filtros de rol/estado, paginación y detalle del usuario.
- Crear una cuenta nueva con nombre, correo, rol y contraseña temporal.
  Solo los administradores con membresía activa en la empresa pueden crearla.
  El correo existente se rechaza sin vincular ni modificar su cuenta.
- Cambiar entre los roles fijos **Administrador**, **Supervisor** y **Agente**
  (`tenant_admin`, `supervisor`, `operator` en la base de datos).
- Activar o desactivar una membresía exclusivamente en la empresa seleccionada.
  No elimina datos ni modifica el acceso a otras empresas.
- Pestañas de roles y permisos de consulta. Los módulos operativos que todavía
  son demostraciones se identifican como tales.
- En el [constructor de automatizaciones](AUTOMATIZACIONES-DEMO.md),
  Administrador edita y publica para simulación; Supervisor consulta y prueba;
  Agente no tiene acceso. Publicar no activa envíos de WhatsApp.
- Desde **Editar acceso > Nombre y contraseña**, editar el nombre y,
  opcionalmente, asignar otra contraseña temporal. Dejarla vacía conserva la
  actual. Solo se admite para cuentas exclusivas de la empresa, sin membresías
  en otras empresas (incluidas las inactivas), permisos de plataforma ni bloqueo
  global. Las cuentas compartidas se gestionan desde plataforma.
- No incluye invitaciones, eliminación de usuarios, roles personalizados ni
  historial de actividad.

El último inicio de sesión corresponde a la cuenta global de ITONE, no a una
visita a la empresa. Un bloqueo global de plataforma impide el acceso incluso
si la membresía está activa; esta pantalla no elimina ese bloqueo.

## Reglas del servidor

La migración incorpora `tenant_memberships.is_active` y las RPC
`current_tenant_role`, `list_tenant_users` y `update_tenant_user`.

- Solo un administrador activo puede consultar o modificar el equipo.
- No se permite modificar el propio acceso desde este módulo.
- La empresa debe conservar al menos un administrador activo y sin bloqueo
  global cuando se elimina, desactiva o degrada una membresía administrativa.
- Las actualizaciones comprueban el rol y estado anteriores: un cambio
  concurrente requiere actualizar la lista antes de volver a guardar.
- Una membresía explícitamente desactivada prevalece sobre permisos globales o
  concesiones de plataforma para esa misma empresa.
- Las políticas RLS restrictivas complementan las políticas existentes y
  bloquean el acceso de membresías inactivas. Las funciones de WhatsApp y de
  gestión de APIs también verifican el rol actual con la sesión del solicitante.
- El shell vuelve a comprobar acceso y rol cada 30 segundos. Las comprobaciones
  de base de datos y de las funciones no dependen de esperar ese intervalo.
- Los logos públicos conservan su lectura pública; sus modificaciones requieren
  acceso administrativo activo.
- Las cuentas nuevas deben cambiar su contraseña al entrar. La contraseña
  temporal requiere entre 12 y 128 caracteres, mayúscula, minúscula y número.
  Se comparte por un canal seguro: no se envía un correo ni se muestra nuevamente
  después de crear la cuenta. El administrador debe comprobar el destinatario,
  ya que estas cuentas se crean con el correo confirmado, sin verificación por email.
- `create-tenant-user` usa Auth Admin solo en el servidor y finaliza el perfil y
  la membresía en una transacción mediante una RPC exclusiva del servicio. Si
  falla, intenta retirar únicamente la cuenta recién creada y notifica cualquier
  fallo de esa compensación.
- El requisito de cambio de contraseña está en `app_metadata`, no controlado por
  el usuario. `current_tenant_role` no concede acceso hasta un cambio real de
  contraseña; un trigger de Auth libera el requisito al cambiar el hash.
- `manage-tenant-user` valida sesión y rol, calcula un hash bcrypt de coste 12
  y llama a una RPC exclusiva del servicio. La RPC comprueba de nuevo el
  administrador, el aislamiento de la cuenta y el nombre esperado antes de
  guardar. Usa bloqueos de tablas de permisos durante esta transacción corta
  para impedir que otra empresa reciba acceso a mitad del cambio.
  La edición de credenciales escribe el hash compatible con Supabase Auth
  directamente en la misma transacción que el perfil: evita la ventana entre
  validar aislamiento y una llamada separada a Auth Admin. No transmite la
  contraseña en claro a SQL ni almacena contraseñas recuperables.
- Al restablecer la contraseña se eliminan sesiones y tokens de refresco del
  usuario y se exige un nuevo cambio de contraseña antes de acceder a datos.
  Un JWT ya emitido no se puede retirar del navegador, pero el rol consultado en
  base de datos queda bloqueado inmediatamente mientras esté pendiente el cambio.
  La nueva contraseña temporal requiere al menos 12 caracteres, mayúscula,
  minúscula y número, y como máximo 72 bytes UTF-8 (límite de bcrypt). Nunca se
  muestra la contraseña anterior.

Las nuevas tablas con `tenant_id` deben tener RLS y comprobar también
`current_tenant_role(tenant_id)`: la migración aplica sus políticas a las tablas
existentes en el momento de ejecutarse, no a tablas creadas posteriormente.

## Activación en Supabase y despliegue web

1. Aplicar primero
   [20261106150000_tenant_user_management.sql](../supabase/migrations/20261106150000_tenant_user_management.sql)
   y después
   [20261106160000_create_tenant_users.sql](../supabase/migrations/20261106160000_create_tenant_users.sql)
   y
   [20261106170000_edit_tenant_user_accounts.sql](../supabase/migrations/20261106170000_edit_tenant_user_accounts.sql)
   mediante las migraciones habituales o el SQL Editor del proyecto. Ejecuta
   únicamente las migraciones que aún no hayas aplicado, en ese orden.
2. Desplegar las funciones actualizadas:

   ```powershell
   npx supabase functions deploy send-whatsapp-message
   npx supabase functions deploy validate-whatsapp-integration
   npx supabase functions deploy register-whatsapp-number
   npx supabase functions deploy manage-internal-api
   npx supabase functions deploy connect-whatsapp-coexistence
   npx supabase functions deploy create-tenant-user
   npx supabase functions deploy manage-tenant-user
   ```

3. Publicar el frontend con el flujo habitual de GitHub / Cloudflare.

El despliegue de Cloudflare no aplica migraciones ni publica Edge Functions.
Esta versión del frontend requiere la migración antes de publicarse.

## Pruebas

```powershell
flutter analyze --no-pub
flutter test --no-pub test\tenant_users_panel_test.dart test\widget_test.dart
npx --yes --package=deno deno test --no-lock --allow-read --allow-env supabase\tests\tenant_user_management_test.ts supabase\tests\whatsapp_coexistence_test.ts
npx --yes --package=deno deno test --no-lock supabase\functions\_shared\tenant_user_creation_test.ts
npx --yes --package=deno deno test --no-lock supabase\functions\_shared\tenant_user_account_test.ts
```
