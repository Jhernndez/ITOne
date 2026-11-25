# APIs externas por empresa

El panel `ExternalApiPanel(tenantId: ...)` administra únicamente APIs de la
empresa; no configura Meta ni WhatsApp. Requiere una sesión de administrador
del tenant. Crear una integración con nombre, URL base HTTPS pública y
autenticación opcional (API key en cabecera, bearer o Basic); añadir recursos
con ruta relativa y método GET, POST, PUT, PATCH o DELETE. Editar o eliminar
desde la tarjeta. Al editar, dejar las credenciales vacías conserva sus valores
si el tipo de autenticación no cambia. Al cambiarlo se requieren las nuevas.
Nunca se muestran las credenciales guardadas.
Las configuraciones antiguas `oauth2` no son compatibles con este ejecutor:
deben cambiarse explícitamente a un tipo admitido antes de poder guardarlas o
ejecutarlas.

La prueba de conexión hace un GET a la URL base. Para ejecutar un recurso,
introducir un objeto JSON de parámetros de consulta con valores simples y,
opcionalmente, un cuerpo JSON para métodos distintos de GET. Antes de ejecutar
un método de escritura o eliminar configuraciones se solicita confirmación.
El panel muestra el código HTTP y la respuesta real; HTTP no exitoso no se
presenta como éxito. Una operación con resultado desconocido puede haberse
aplicado y no debe repetirse sin comprobar primero el sistema externo.

## Automatización

Cada recurso tiene dos permisos independientes, ambos desactivados por
defecto: **Permitir en automatizaciones** y **Permitir escrituras automáticas**.
El segundo es imprescindible para POST, PUT, PATCH y DELETE. Ambos controles
son verificados en el servidor en cada ejecución, además de la habilitación
de integración y recurso y de su pertenencia al tenant. La activación del bot
es independiente y no la realiza este módulo.

El ejecutor de confianza importa
`supabase/functions/_shared/external_api.ts` y llama:

```ts
const result = await executeExternalResource(admin, {
  tenantId, resourceId, query, body, automation: true, idempotencyKey,
});
```

`admin` es el cliente Supabase de servicio del ejecutor, no un cliente del
navegador. `query` es un objeto JSON plano (string, número, booleano o null);
`body` es JSON opcional y se ignora en GET; los filtros GET se envían en
`query`. Se devuelve exactamente `{ok: boolean, status_code: number, body: JSON}`
para una respuesta HTTP completa: 2xx tiene `ok: true`; 4xx/5xx tiene
`ok: false` sin lanzar excepción. El cuerpo puede ser objeto, array, escalar
JSON o texto. No existe `result.data`: mapear `result.body.campo`; usar
`result.body.data` únicamente si el proveedor devuelve una propiedad `data`.
Si el runtime guarda el resultado completo en una variable, navegar desde
`variable.body`; si guarda solo el cuerpo, navegar desde `variable`.

Los fallos de red o timeout lanzan errores sanitizados, también para
POST/PUT/PATCH/DELETE, y nunca fabrican una respuesta HTTP o éxito.
`ExternalApiError` expone `status` y `outcome`: `not_sent`
(sin solicitud enviada), `responded` (hubo respuesta, por ejemplo una
redirección bloqueada), o `unknown` (no se sabe si se aplicó). Nunca reintentar
automáticamente una escritura con resultado desconocido. `idempotencyKey` se
envía como `Idempotency-Key`; su deduplicación depende del proveedor y no está
garantizada. Una respuesta 5xx o una redirección tampoco garantiza que no se
haya aplicado la escritura. El helper no reintenta solicitudes.

Para el selector, consultar `tenant_api_resources` por `tenant_id`,
`enabled = true` y `enabled_for_automation = true`; las columnas son
`id,name,integration_id,http_method,enabled_for_automation,allow_automation_writes`.
La columna del método es `http_method`, no `method`; se puede consultar como
`method:http_method` si el consumidor necesita ese alias. El ejecutor debe
tratar la selección como no confiable y llamar al helper con el tenant real.

## Seguridad y despliegue

Aplicar `20261106210000_external_api_security.sql` y desplegar la función
`manage-internal-api` junto con sus módulos compartidos. La migración reemplaza
el permiso SELECT de tabla por permisos de columnas explícitos para que
`auth_config` no sea legible por usuarios autenticados; las credenciales se
modifican exclusivamente mediante la función con comprobación de administrador.
La base de datos conserva las credenciales para realizar las llamadas: usar las
protecciones operativas y de acceso habituales de Supabase.

Solo se permiten dominios HTTPS públicos en el puerto 443. La resolución IPv4
se comprueba y fija en la conexión, con verificación TLS del nombre original.
Se bloquean IP privadas/reservadas, URLs con credenciales, rutas que cambien
origen o naveguen hacia arriba y todas las redirecciones. IPv6-only no está
soportado. La solicitud JSON se limita a 64 KiB, la respuesta a 256 KiB y el
tiempo total a 10 segundos. El resultado se limpia de valores de credenciales
conocidos, pero no se deben devolver ni almacenar datos sensibles de negocio
innecesariamente. No hay reintentos de mutaciones. La ejecución requiere acceso
de red y DNS desde el runtime de Supabase Edge; no se necesita acceso directo a
la base de datos desde el proveedor externo.
