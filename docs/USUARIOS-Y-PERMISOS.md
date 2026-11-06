# Usuarios y permisos por empresa

El módulo **Usuarios y permisos** está disponible para administradores de la
empresa. Consulta las membresías reales de Supabase: no crea usuarios de muestra.

## Alcance

- Búsqueda, filtros de rol/estado, paginación y detalle del usuario.
- Cambiar entre los roles fijos **Administrador**, **Supervisor** y **Agente**
  (`tenant_admin`, `supervisor`, `operator` en la base de datos).
- Activar o desactivar una membresía exclusivamente en la empresa seleccionada.
  No elimina datos ni modifica el acceso a otras empresas.
- Pestañas de roles y permisos de consulta. Los módulos operativos que todavía
  son demostraciones se identifican como tales.
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

Las nuevas tablas con `tenant_id` deben tener RLS y comprobar también
`current_tenant_role(tenant_id)`: la migración aplica sus políticas a las tablas
existentes en el momento de ejecutarse, no a tablas creadas posteriormente.

## Activación en Supabase y despliegue web

1. Aplicar primero
   [20261106150000_tenant_user_management.sql](../supabase/migrations/20261106150000_tenant_user_management.sql)
   mediante las migraciones habituales o el SQL Editor del proyecto.
2. Desplegar las funciones actualizadas:

   ```powershell
   npx supabase functions deploy send-whatsapp-message
   npx supabase functions deploy validate-whatsapp-integration
   npx supabase functions deploy register-whatsapp-number
   npx supabase functions deploy manage-internal-api
   npx supabase functions deploy connect-whatsapp-coexistence
   ```

3. Publicar el frontend con el flujo habitual de GitHub / Cloudflare.

El despliegue de Cloudflare no aplica migraciones ni publica Edge Functions.
Esta versión del frontend requiere la migración antes de publicarse.

## Pruebas

```powershell
flutter analyze --no-pub
flutter test --no-pub test\tenant_users_panel_test.dart test\widget_test.dart
npx --yes --package=deno deno test --no-lock --allow-read --allow-env supabase\tests\tenant_user_management_test.ts supabase\tests\whatsapp_coexistence_test.ts
```
