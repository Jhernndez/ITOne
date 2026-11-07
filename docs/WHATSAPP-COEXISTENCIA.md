# WhatsApp Business con coexistencia

## Que cambia

ITONE conecta la cuenta existente de WhatsApp Business mediante Meta Embedded
Signup. El mismo numero puede utilizarse desde el celular y desde ITONE cuando
Meta confirma `is_on_biz_app=true` y `platform_type=CLOUD_API`.

- Solo el administrador de la empresa puede conectar su canal.
- El token de cada empresa se guarda en `whatsapp_accounts.access_token`, que no
  es legible por clientes autenticados. Nunca se envia al frontend.
- Los mensajes del celular llegan por `smb_message_echoes`.
- El historial autorizado llega por `history`, hasta 180 dias segun Meta.
- La solicitud de contactos e historial se inicia una vez, inmediatamente
  despues del onboarding. Actualizar estado no vuelve a solicitarla.
- La firma de todos los POST del webhook se verifica con `META_APP_SECRET`.
- Importar historial no genera notificaciones de mensajes nuevos. Los chunks
  se guardan en transacciones de hasta 200 mensajes; Meta recibe confirmacion
  solo despues de persistirlos. Los reintentos no duplican mensajes.

La conexion anterior de Cloud API permanece visible para diagnostico. No existe
una conversion automatica de un numero ya migrado, bloqueado o desconectado del
celular. Antes de intentar coexistencia con ese numero, consulta su elegibilidad
y el procedimiento de reincorporacion con Meta. No elimines la cuenta como prueba.

## Evidencia de mensajeria sin modificar el numero de produccion

En **Configuracion > WhatsApp > Prueba Meta**, el administrador puede enviar una
plantilla real desde ITONE usando el numero de prueba de Meta. Este panel no
registra ni desvincula numeros, no necesita coexistencia y no ejecuta flujos.
Es una herramienta temporal de revision, no un conector general para clientes.

Preparacion del servidor:

1. Aplicar [20261106201500_whatsapp_review_attempts.sql](../supabase/migrations/20261106201500_whatsapp_review_attempts.sql).
2. En **Supabase > Edge Functions > Secrets**, configurar:

   | Secreto | Valor |
   | --- | --- |
   | `WHATSAPP_REVIEW_TENANT_ID` | UUID de la empresa autorizada, de `public.tenants.id` |
   | `WHATSAPP_REVIEW_PHONE_NUMBER_ID` | Phone Number ID del numero **de prueba** en API Setup; no el WABA ID |
   | `WHATSAPP_REVIEW_RECIPIENT` | Destinatario de prueba verificado en Meta, con codigo de pais, solo digitos |
   | `WHATSAPP_REVIEW_ACCESS_TOKEN` | Token vigente generado para ese numero de prueba |

   `META_GRAPH_VERSION`, si existe, se reutiliza. Sin ese secreto, esta funcion
   usa `v25.0`. El token temporal puede caducar; renovarlo en Meta y actualizar
   el secreto si Meta devuelve un error de autenticacion.

3. Desplegar la nueva funcion con autenticacion JWT habilitada:

   ```powershell
   supabase functions deploy send-whatsapp-review
   ```

4. Publicar el frontend. GitHub / Cloudflare no aplica SQL ni despliega funciones.
5. Iniciar sesion como administrador de la empresa autorizada y abrir la pestana.
   Revisar ID y destinatario; marcar la confirmacion y pulsar
   **Enviar plantilla real de prueba**.

La plantilla es `jaspers_market_order_confirmation_v1`, idioma `en_US`, parametros
`John Doe`, `123456`, `Nov 6, 2026`: los mismos que se comprobaron en API Setup.
Solo funcionara si esa plantilla esta disponible en la cuenta de prueba.
No se aceptan destinos, tokens ni plantillas arbitrarios enviados por el cliente.
No guardar estos secretos en Flutter, GitHub, documentos o Cloudflare ni pegarlos
en el chat. Al terminar la revision, retirar los cuatro secretos para deshabilitar
el panel.

El endpoint comprueba el rol actual y la empresa configurada. Reserva cada intento
en PostgreSQL bajo bloqueo de la empresa: uno por minuto y veinte en 24 horas,
incluidos los fallidos. Solo `service_role` puede reservar intentos; las tablas
no son legibles por usuarios del frontend. La reserva cuenta intentos, no certifica
entregas. Las llamadas a Meta no se reintentan automaticamente.

El resultado muestra el ID real de Meta y aclara que aceptado no significa
entregado. Confirmar la recepcion en WhatsApp antes de reintentar un fallo ambiguo.
Estos mensajes de prueba no se incorporan a la bandeja de produccion.

La cabecera de Integracion distingue Cloud API de coexistencia segun la modalidad
guardada. Su estado corresponde a ITONE, no garantiza capacidad de envio en Meta.
Para el video, mostrar ITONE enviando y el nuevo mensaje recibido en WhatsApp.
Empezar la grabacion directamente en Prueba Meta, sin pasar por Integracion ni
mostrar los identificadores y el numero de produccion.
No mostrar tokens ni conversaciones ajenas. Para `whatsapp_business_management`,
grabar por separado la creacion de una plantilla desde Plantillas de ITONE
o WhatsApp Manager.
La aceptacion de la evidencia depende de Meta.

Pruebas locales:

```powershell
flutter test --no-pub test\whatsapp_review_panel_test.dart
npx --yes --package=deno deno test --no-lock --allow-read --allow-env supabase\functions\_shared\whatsapp_review.test.ts supabase\tests\whatsapp_review_test.ts
```

## Plantillas de produccion por empresa

En **Configuracion > WhatsApp > Plantillas**, el administrador puede seleccionar
una cuenta de su empresa y listar, crear, editar o eliminar sus plantillas reales
en Meta. No utiliza los secretos `WHATSAPP_REVIEW_*`, no envia mensajes y no
modifica la conexion del numero ni su registro en el celular.
Configuracion ocupa el ancho y la altura disponibles junto al menu principal;
el listado de plantillas se desplaza dentro del panel, sin una altura fija de
500 pixeles.

Requisitos y despliegue:

1. La cuenta debe tener su WABA y token propio guardados por el servidor en
   `whatsapp_accounts`. El token necesita `whatsapp_business_management` y acceso
   a ese WABA. Si falta o caduco, configurar las credenciales por el procedimiento
   seguro del servidor; no hay respaldo con un token global o de Prueba Meta.
2. Desplegar la funcion con autenticacion JWT habilitada:

   ```powershell
   supabase functions deploy manage-whatsapp-templates
   ```

3. Publicar el frontend. Este modulo no requiere nuevas migraciones SQL.
   GitHub / Cloudflare no despliega automaticamente la funcion.

El servidor vuelve a comprobar usuario, rol y empresa en cada peticion, carga
solo las cuentas de ese tenant y verifica que la plantilla pertenece al WABA
seleccionado antes de editar o eliminar. El token nunca se devuelve al cliente.
Meta es la fuente de las plantillas y sus estados, sin copias locales en SQL.

Contenido compatible con este editor:

- Categorias **UTILITY** y **MARKETING**.
- Idiomas `es`, `es_ES`, `es_MX`, `en_US`, `pt_BR`.
- Encabezado de texto opcional (60 caracteres), cuerpo (1024) y pie opcional
  sin variables (60).
- Variables numericas consecutivas `{{1}}`, `{{2}}`, etc., con un ejemplo
  ficticio por variable. El encabezado admite solo `{{1}}`.
- Hasta tres botones: respuestas rapidas, o hasta dos URL HTTPS fijas y un
  telefono internacional. No mezclar respuestas rapidas con enlaces/telefono.
- Vista previa del contenido antes de enviarlo.

Crear envia la plantilla a revision; el ID y estado mostrados son los de Meta,
no una aprobacion local. Editar conserva nombre, idioma y categoria. Las
plantillas multimedia, de autenticacion, con variables con nombre o botones
avanzados se consultan aqui pero deben editarse en WhatsApp Manager para no
perder componentes. Eliminar requiere confirmacion y apunta al ID e idioma
seleccionados, no a todas las traducciones del mismo nombre.

Meta decide aprobacion, recategorizacion, estados editables y limites de cambios.
Los errores se muestran en pantalla; las mutaciones no se reintentan
automaticamente. Si hay una respuesta ambigua, actualizar el listado antes de
reintentar. Una plantilla aprobada en otro WABA no se transfiere a esta cuenta.
No se garantiza que una plantilla nueva este aprobada o lista para enviar.

Pruebas locales:

```powershell
flutter test --no-pub test\whatsapp_templates_panel_test.dart
npx --yes --package=deno deno test --no-lock --allow-env supabase\functions\_shared\whatsapp_templates.test.ts
```

## 1. Preparar la app en Meta

1. Abre [Meta Developers](https://developers.facebook.com/apps/) y selecciona tu
   app empresarial, asociada a tu portafolio empresarial.
2. Completa los requisitos para operar como
   [Tech Provider](https://developers.facebook.com/documentation/business-messaging/whatsapp/solution-providers/get-started-for-tech-providers).
   Tener una app con un numero propio conectado no equivale a tener aprobado
   el onboarding de numeros de otras empresas. Completa la verificacion
   empresarial y las revisiones que Meta solicite.
3. En **App settings > Basic**, configura dominio de la app, URL publica de
   privacidad y procedimiento/URL de eliminacion de datos. Copia el **App ID**.
   El **App Secret** se guarda solo en Supabase.
4. Agrega **Facebook Login for Business**. En **Settings**, activa el login
   mediante SDK JavaScript y configura los dominios permitidos del SDK, incluido
   el dominio HTTPS de produccion de Cloudflare. Configura tambien las URLs OAuth
   que Meta solicite para ese dominio. No uses comodines abiertos.
5. En **Facebook Login for Business > Configurations > Create configuration**,
   selecciona **Embedded Signup** y el producto **WhatsApp Cloud API**.
   Utiliza una configuracion de Embedded Signup **v4**. La version del flujo es
   distinta de la version de Graph API. Este cliente usa
   `featureType=whatsapp_business_app_onboarding` y `sessionInfoVersion=3`.
6. Selecciona los activos y permisos requeridos por el producto. Para Cloud API,
   Meta documenta **Advanced Access** para `whatsapp_business_management` y
   `whatsapp_business_messaging`. Solicita la revision de los permisos
   seleccionados y conserva el **Configuration ID**.
7. Para incorporar empresas ajenas a los roles de prueba de tu app, completa
   las aprobaciones de Meta y publica la app en **Live**. Los nombres y ubicaciones
   del dashboard pueden variar; sigue los requisitos que muestre tu app.

Referencia: [configuracion Embedded Signup v4](https://developers.facebook.com/documentation/business-messaging/whatsapp/embedded-signup/version-4).

## 2. Configurar Supabase antes de publicar el nuevo webhook

Aplica la migracion [20261106123000_whatsapp_coexistence.sql](../supabase/migrations/20261106123000_whatsapp_coexistence.sql)
sobre la base que ya tenga las migraciones anteriores de ITONE.

En **Supabase > Edge Functions > Secrets**, configura:

| Secreto | Valor |
| --- | --- |
| `META_APP_ID` | App ID de la app de Meta |
| `META_APP_SECRET` | App Secret de esa misma app |
| `META_WHATSAPP_CONFIG_ID` | Configuration ID de Embedded Signup |
| `META_GRAPH_VERSION` | Version vigente de Graph API para tu app; por defecto `v23.0` |
| `WHATSAPP_VERIFY_TOKEN` | Valor privado elegido para verificar el callback en Meta |

Los secretos de Supabase habituales (`SUPABASE_URL`, claves de backend) siguen
siendo necesarios. No pongas el App Secret, tokens de empresas ni service-role
en GitHub, Cloudflare, Flutter, `--dart-define` o metadata publica.

Despliega las funciones:

```powershell
supabase functions deploy connect-whatsapp-coexistence
supabase functions deploy send-whatsapp-message
supabase functions deploy validate-whatsapp-integration
supabase functions deploy register-whatsapp-number
supabase functions deploy whatsapp-webhook --no-verify-jwt
```

El webhook no puede exigir JWT de Supabase porque lo llama Meta; exige la firma
HMAC de Meta. Las otras funciones autentican al usuario dentro del handler.
Si tu proyecto utiliza claves JWT asimetricas y el gateway no las acepta,
configura `verify_jwt=false` para esas funciones siguiendo la documentacion de
Supabase: no elimines la autenticacion `auth.getUser()` del handler.

`WHATSAPP_ACCESS_TOKEN` se conserva solo como compatibilidad con integraciones
anteriores de Cloud API. Las cuentas de coexistencia no utilizan ese fallback.

## 3. Configurar los webhooks en Meta

1. Abre **WhatsApp > Configuration** o el producto **Webhooks** de tu app.
2. Configura el callback:
   `https://<PROJECT_REF>.supabase.co/functions/v1/whatsapp-webhook`.
3. Introduce el mismo valor de `WHATSAPP_VERIFY_TOKEN` y verifica el callback.
4. En el objeto **whatsapp_business_account**, suscribe estos campos:
   - `messages`
   - `smb_message_echoes`
   - `smb_app_state_sync`
   - `history`
5. Las suscripciones a campos se configuran en Meta. ITONE realiza ademas
   `POST /<WABA_ID>/subscribed_apps` al completar cada onboarding.

No uses un token de verificacion como App Secret: sirven para cosas distintas.
El nuevo webhook rechazara POST sin firma o firmados por otra app.

## 4. Conectar cada empresa

1. Entra a ITONE web con el rol **tenant_admin** de la empresa.
2. Abre **Configuracion > WhatsApp > Integracion**.
3. Pulsa **Conectar WhatsApp Business**. Si aparece que falta configuracion,
   revisa los secretos y aprobaciones anteriores. Permite la ventana emergente.
4. En Meta, selecciona la cuenta **existente de WhatsApp Business** que sigue
   funcionando en el celular. No elijas crear un numero exclusivo de Cloud API.
5. Completa los pasos de verificacion/conexion que indique Meta en el celular.
6. Autoriza compartir el historial si quieres importarlo. ITONE muestra el
   resultado y progreso; Meta puede rechazar el historial con `2593109` cuando
   la empresa no lo autoriza.
7. Mantente disponible mientras se sincroniza y pulsa **Actualizar estado** para
   consultar el avance. Meta exige iniciar la sincronizacion dentro de las
   primeras 24 horas del onboarding. No repitas solicitudes a ciegas si fallan:
   guarda los request IDs y revisa Meta; repetir el onboarding puede requerir
   desconectar primero desde WhatsApp Business.
8. Comprueba un texto entrante nuevo, una respuesta desde ITONE y un mensaje
   enviado desde el celular. Este ultimo debe aparecer con **Desde el celular**.

ITONE omite `POST /<PHONE_NUMBER_ID>/register`: Meta indica que los numeros
incorporados con coexistencia ya estan registrados.

## Limites y diagnostico

- Coexistencia no desbloquea `131031`. Revisa **Business Support Home** y el
  estado de salud del numero. Puede existir una restriccion o un problema con
  los datos de registro; el codigo por si solo no identifica la causa.
- La ventana de 24 horas aplica a mensajes libres enviados por API, no al
  envio manual desde WhatsApp Business. El envio actual de ITONE es texto:
  el envio de plantillas fuera de esa ventana no esta implementado aqui.
- El historial excluye grupos. Meta limita los IDs de adjuntos historicos a
  mensajes de los ultimos 14 dias. ITONE importa textos, captions y marcadores
  de medios; no descarga ni reproduce esos adjuntos.
- Los contactos sin telefono se conservan por el ID de usuario de Meta
  (BSUID), scoped a la cuenta empresarial. El envio actual requiere que Meta
  comparta el telefono del destinatario; no se inventa un numero.
- Las credenciales estan protegidas por permisos de columnas y se usan solo
  en backend. No se ha agregado un sistema de rotacion o cifrado aplicativo.
- Si la empresa desconecta la plataforma desde WhatsApp Business, usa
  **Validar conexion con Meta** para detectar que Meta ya no confirma
  coexistencia. No se ha agregado procesamiento de `account_update`.

## Publicar la web

El workflow [deploy.yml](../.github/workflows/deploy.yml) compila Flutter y
publica en Cloudflare Pages al hacer push a `main`. Sus secretos de GitHub son
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `CLOUDFLARE_API_TOKEN` y
`CLOUDFLARE_ACCOUNT_ID`. El proyecto de Pages configurado es `itone-frontend`.

Publicar en Cloudflare no ejecuta migraciones ni despliega Edge Functions.
Completa los pasos de Supabase por separado para activar la nueva conexion.

## Validacion local

```powershell
flutter analyze
flutter test
flutter build web --release
node --experimental-strip-types --test supabase\functions\_shared\whatsapp_webhook.test.ts test\whatsapp_signup_test.js
deno check supabase\functions\connect-whatsapp-coexistence\index.ts supabase\functions\whatsapp-webhook\index.ts supabase\functions\send-whatsapp-message\index.ts supabase\functions\validate-whatsapp-integration\index.ts
deno test --no-lock --allow-read --allow-env supabase\tests\whatsapp_coexistence_test.ts
```

La prueba SQL utiliza PostgreSQL en memoria (PGlite), sin tocar Supabase remoto.
La conexion real, permisos y entrega se deben probar con una app de Meta aprobada
y un numero elegible; las pruebas locales no sustituyen esa verificacion.
