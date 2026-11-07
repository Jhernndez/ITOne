# Constructor de automatizaciones para simulación

En **Automatizaciones**, cada empresa dispone de sus propios flujos, borradores
y versiones. El editor ocupa toda el área disponible, sin el contenedor central
ni el scroll de página de los otros módulos. En escritorio se organiza en
biblioteca de componentes, lienzo y configuración lateral con edición directa.
Los paneles tienen su propio scroll si su contenido es largo.

**Publicar para simulación no activa WhatsApp.** Ningún bloque de esta entrega
envía mensajes, invoca APIs, procesa con IA ni asigna agentes reales. Usar solo
ejemplos ficticios, sin datos personales ni clínicos reales.

## Activación

Aplicar una vez en Supabase la migración
[20261106183000_automation_flows.sql](../supabase/migrations/20261106183000_automation_flows.sql),
después de las migraciones anteriores de usuarios y permisos. Luego publicar
el frontend mediante GitHub / Cloudflare. No requiere Edge Functions nuevas.
Después aplicar
[20261106193000_expand_automation_canvas.sql](../supabase/migrations/20261106193000_expand_automation_canvas.sql):
actualiza el validador para admitir coordenadas extendidas y ciclos. No recrea
tablas ni modifica las instantáneas anteriores.
Cloudflare no aplica estas migraciones automáticamente.

## Permisos y almacenamiento

- Administrador activo: crear, editar, guardar borradores y publicar versiones
  exclusivamente para simulación.
- Supervisor activo: consultar y probar borradores y versiones, sin escritura.
- Agente: no tiene acceso al constructor ni a sus tablas.
- Las tablas `automation_flows` y `automation_flow_versions` tienen RLS basada en
  `current_tenant_role`. Esto incluye membresías inactivas y bloqueos globales.
- Las escrituras pasan por RPC administrativas. No se conceden escrituras
  directas al cliente.
- Cada guardado comprueba la revisión anterior para evitar sobrescribir cambios
  de otro administrador. Ante conflicto, conservar los cambios que se necesiten
  y recargar antes de volver a editar; recargar descarta el lienzo local.
- Las versiones son instantáneas inmutables con número, autor, nombre y grafo.
  Editar un borrador no cambia una versión ya publicada.
- La conversación de prueba solo existe en memoria y se descarta al cerrarla.
  Las modificaciones del lienzo solo persisten después de **Guardar borrador**.
  Guardar antes de salir del módulo, cambiar de empresa o cerrar la pestaña.

## Uso del editor

1. Pulsar **Nuevo flujo** o **Plantilla EPS / Particular**.
2. Escribir un nombre. Buscar componentes por nombre en la biblioteca y pulsar
   uno para añadirlo, o arrastrarlo al lienzo. En pantallas estrechas, abrir la
   biblioteca con el botón de componentes situado abajo en el lienzo.
3. Mover cada bloque arrastrando su icono o cabecera. Arrastrar el fondo para
   desplazar el lienzo sin bordes fijos; usar la rueda del ratón, pellizcar con
   dos dedos o los botones de zoom. **Ajustar flujo** encuadra los bloques;
   **Restablecer vista** vuelve al origen.
4. Seleccionar un bloque y editar sus campos directamente en **Configuración**.
   Los cambios se aplican al borrador mientras se escribe; guardar para
   persistirlos. En pantallas estrechas, el panel aparece debajo del lienzo;
   puede cerrarse para recuperar espacio.
5. Para conectar, pulsar la salida del bloque y luego el bloque destino.
   Alternativamente, usar los selectores de salida en el panel de configuración.
   Elegir otro destino sustituye la conexión de esa salida.
6. Usar **Desconectar** o **Eliminar bloque** para retirar conexiones o nodos.
   Cambiar los nombres de las opciones retira conexiones de salidas inexistentes:
   volver a conectar esas ramas.
7. **Guardar borrador** permite conservar trabajo incompleto. **Probar
   automatización** valida y ejecuta una copia del grafo actual, incluidos cambios
   aún no guardados. La copia no cambia si después se modifica el borrador.
8. **Publicar para simulación** valida, guarda si hace falta y crea una versión.
   En **Versiones**, elegir una versión para probar exactamente esa instantánea.
9. **Pantalla completa** oculta la cabecera y el menú de la aplicación sin
   perder los cambios. **Salir de pantalla completa** los restaura.

### Bloques

| Bloque | Comportamiento |
|---|---|
| Inicio | Único punto de entrada |
| Enviar texto | Muestra el mensaje en la conversación ficticia |
| Pregunta | Espera texto y guarda la respuesta en una variable |
| Opciones | Muestra de 2 a 6 opciones únicas, separadas por `\|`; guarda la selección y sigue su rama |
| Condición | Compara una variable existente con un valor, sin distinguir mayúsculas; ramas Sí / No |
| API simulada | El probador elige Éxito o Error; no hace llamadas |
| Revisión de agente | El probador elige Aprobada o Denegada; denegar exige motivo ficticio |
| Transferir a humano | Termina la simulación con un aviso; no asigna agentes reales |
| Finalizar | Termina el recorrido |

Variables: identificadores de 1 a 40 caracteres, empezando por letra, con letras,
números y `_`. Los mensajes pueden incluir `{{variable}}`. La denegación guarda
`motivo_denegacion`. Referenciar una variable que no existe detiene la prueba
con un error explícito; no inventa información.

La validación exige un Inicio, ramas completas, destinos existentes, identificadores
únicos y bloques alcanzables. Se puede volver a un bloque anterior, incluso al
mismo bloque, excepto a Inicio. Una pregunta u opción dentro de un ciclo permite
repetir una conversación y elegir cuándo salir. Un ciclo exclusivamente automático
se detiene con un error explícito tras 100 pasos sin esperar una respuesta.
La prueba completa tiene un límite de 1000 pasos para no consumir memoria
indefinidamente; reiniciar la prueba para comenzar otra sesión.

El lienzo se desplaza en ambas direcciones sin el antiguo borde de 2900 × 1800.
Solo se dibuja la cuadrícula del área visible. El rango numérico de las posiciones
es de -1000000000 a 1000000000 en ambos ejes: «infinito» describe la navegación,
no una cantidad ilimitada de bloques ni de ejecución.
Máximo 60 bloques, 180 conexiones
y 1000 caracteres por campo de configuración; grafo almacenado de máximo 200 KB.
La publicación también se valida en PostgreSQL, no solo en Flutter.

## Ejemplo IPS / Salud

La plantilla es editable, no un guion independiente del constructor:

- EPS solicita EPS ficticia y servicio.
- Particular solicita servicio y nombre ficticio de examen, o la respuesta
  «No tengo». No admite documentos.
- Ambas ramas llegan a una API simulada.
- Error: mensaje de fallo y transferencia humana, sin confirmar solicitud.
- Éxito: revisión simulada. Aprobada deja la solicitud pendiente sin confirmar
  cita. Denegada muestra el motivo y deriva a atención humana.

No se verifica cobertura, tarifa, autorización ni disponibilidad real.
Las demostraciones locales anteriores de horario y conversación fija permanecen
como ejemplos internos con sus pruebas; el menú ahora abre el constructor.

## Fuera de alcance

Envíos de WhatsApp, interpretación con IA, conectores externos reales, esperas
durables, programación horaria y activación sobre webhooks requieren un motor
de servidor adicional. Las versiones de esta entrega tienen `mode=simulation`.
No hay ejecución automática ni publicación para producción.

## Validación

```powershell
flutter analyze --no-pub
flutter test --no-pub test\flow_graph_test.dart test\flow_builder_test.dart
npx --yes --package=deno deno test --no-lock --allow-read --allow-env supabase\tests\automation_flows_test.ts
flutter build web --no-pub
```
