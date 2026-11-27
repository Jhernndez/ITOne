# Automatizaciones de WhatsApp

## Puesta en marcha por empresa

1. Conecta el número en **Configuración → WhatsApp → Integración** mediante coexistencia.
2. Crea un flujo en **Automatizaciones**, conecta todas las salidas y guarda el borrador.
3. Usa **Probar automatización**: esta herramienta no envía mensajes ni llama APIs.
4. Publica una versión inmutable.
5. En **Configuración → WhatsApp → Respuestas automáticas**, selecciona número y versión y confirma la activación de respuestas reales.

Todos los bots empiezan desactivados. Publicar, desplegar o actualizar un flujo nunca activa un número. Cada número tiene una versión seleccionada; las conversaciones en curso conservan su versión hasta terminar o reiniciarse.

Las versiones antiguas marcadas `simulation` permanecen inmutables y requieren la misma activación explícita. Las nuevas versiones se marcan `published`.

## Respaldos y eliminación

En el constructor, **Exportar respaldo** descarga un JSON con el último borrador guardado y las versiones publicadas; no incluye cambios sin guardar, vínculos de números ni sesiones. El archivo puede contener datos sensibles de la configuración: guárdalo de forma segura.

**Restaurar respaldo** crea un flujo nuevo en la misma empresa de origen, con sus versiones, sin sobrescribir flujos ni activar bots. Los recursos API referenciados deben seguir disponibles y autorizados al activar una versión. El respaldo admite hasta 1000 versiones y 20 MB.

Un administrador puede eliminar un flujo completo o una versión tras confirmar. Se bloquea la eliminación si existe cualquier vínculo con un número (incluso desactivado) o una sesión de WhatsApp, para preservar la operación y el historial. No se eliminan vínculos ni sesiones automáticamente. Las versiones eliminadas no se reutilizan al publicar nuevamente. Un supervisor puede exportar y probar, pero no restaurar ni eliminar.

## Bloques

- Texto: envía un mensaje de hasta 4096 caracteres.
- Pregunta: guarda la siguiente respuesta en su variable.
- Opciones: acepta la etiqueta o su número, y sigue la salida correspondiente.
- Condición: compara la variable con el valor, sin distinguir mayúsculas.
- API: selecciona un recurso habilitado de la empresa; configura consulta/cuerpo como objetos JSON. Solo se admiten valores simples en la consulta. Usa `{{variable}}` en valores de texto. El resultado completo contiene `ok`, `status_code` y `body`; accede con `{{api_result.body.campo}}`. Para comparar un campo en Condición, configura el campo de respuesta opcional, por ejemplo `body.estado`, y guarda ese valor en la variable de resultado. Dejarlo vacío conserva la respuesta completa. Un campo ausente detiene la ejecución; los rechazos HTTP siguen la salida Error con la respuesta completa.
- Revisión: pausa hasta que un operador apruebe o deniegue desde la bandeja. Denegar requiere motivo, disponible en `motivo_denegacion`.
- Atención humana: pausa sin enviar mensajes adicionales.
- Fin: termina; el próximo mensaje inicia un recorrido nuevo.

Variables iniciales: `contact_name`, `contact_phone`, `last_message`. Las variables no existentes producen un error visible; no se sustituyen silenciosamente. Las llamadas API se autorizan según la configuración del recurso en el momento de ejecutarse. Las escrituras requieren consentimiento por recurso, además de habilitar su uso en automatizaciones.

## Control humano y límites

Responder desde ITONE o WhatsApp Business móvil pausa la conversación. También puedes pulsar **Tomar conversación**. La pausa se conserva hasta **Reactivar bot**, que descarta el recorrido y espera un nuevo mensaje. Las respuestas móviles dependen de recibir el webhook de ecos de Meta.

Una acción externa ya enviada no se puede cancelar retroactivamente al tomar la conversación. No se inician nuevas acciones después de registrar la pausa.

Solo los mensajes nuevos de entrada activan el bot. Historial, ediciones, estados y ecos no generan respuestas. Los mensajes no textuales pasan a atención humana. La recepción duplicada del mismo identificador no crea otra ejecución.

Los textos automáticos y manuales requieren una entrada de cliente dentro de las últimas 24 horas. Fuera de esa ventana se requiere una plantilla aprobada o una nueva entrada del cliente; el bot no intenta eludir la política de Meta.

Límites: 30 pasos automáticos, 6 acciones externas consecutivas por evento, 1000 pasos acumulados y 100 KB de estado. Los errores aparecen en la bandeja y en Respuestas automáticas. Los envíos aceptados por Meta se registran en la conversación; los webhooks actualizan su entrega.

## Persistencia y recuperación

El trigger de mensajes encola trabajo transaccionalmente. El worker reclama una conversación por vez con un lease y comprueba la pausa antes de cada efecto. Un registro persistente identifica cada envío/llamada por trabajo y paso.

Las ejecuciones interrumpidas o con resultado externo incierto **no se reintentan automáticamente**: se detienen para revisión humana. Esto evita repetir una compra, actualización o mensaje cuyo resultado no se pudo confirmar. No se promete entrega exactamente una vez en servicios externos.

El webhook despierta al worker; `pg_cron` + `pg_net` recuperan los trabajos pendientes cada minuto. El cron también procesa las revisiones aprobadas/denegadas. Supervisar los trabajos fallidos, el historial de cron y los logs de funciones sigue siendo necesario.

## Despliegue

Aplicar en orden las migraciones de flujos y recursos API, incluida `20261106193000_expand_automation_canvas.sql`, `20261125170000_whatsapp_automation_runtime.sql`, `20261125171000_whatsapp_automation_scheduler.sql`, `20261127170000_automation_flow_lifecycle.sql` y `20261127180000_bot_worker_read_permissions.sql`.

Configurar un secreto aleatorio `WHATSAPP_BOT_WORKER_SECRET` en Edge Function Secrets y el mismo valor en Vault con nombre `itone_bot_worker_secret`. Guardar la URL absoluta de `/functions/v1/whatsapp-bot-worker` en Vault como `itone_bot_worker_url`. No guardar estos valores en Git ni exponerlos a Flutter.

Desplegar `whatsapp-bot-worker` sin verificación JWT (autentica exclusivamente su secreto de worker), `whatsapp-webhook` sin JWT (valida firma de Meta), `send-whatsapp-message` y `manage-internal-api`. No activar bots durante el despliegue. El diagnóstico de Platform solo indica si el secreto del worker está configurado, no revela su valor.

La conexión efectiva sigue dependiendo de la autorización y elegibilidad del número en Meta; desplegar este motor no resuelve restricciones de propiedad del portafolio.

## Pruebas

```powershell
deno test --no-lock --allow-read --allow-env supabase\functions\_shared\automation_runtime.test.ts supabase\tests\whatsapp_bot_test.ts supabase\tests\automation_flows_test.ts supabase\tests\automation_flow_lifecycle_test.ts
flutter test --no-pub test\bot_controls_test.dart test\flow_builder_test.dart
```
