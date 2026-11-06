# Laboratorio de automatizaciones

En el menú de empresa, **Automatizaciones** permite a administradores y
supervisores demostrar respuestas sin depender de Meta.

Esta versión es exclusivamente una simulación local. No llama a Supabase,
no envía WhatsApps ni usa contactos reales. Las reglas y resultados se descartan
al salir del módulo, recargar o cambiar de empresa. No requiere migraciones ni
Edge Functions nuevas.

## Demostración

1. Personalizar los textos de bienvenida y fuera de horario.
2. Elegir apertura y cierre. Es un horario diario ficticio; puede cruzar
   medianoche. La apertura se incluye y el cierre se excluye. No admite apertura
   igual a cierre. No usa calendario semanal, festivos ni zona horaria real.
3. En el simulador, elegir una hora y si la conversación es nueva.
4. Escribir un mensaje ficticio y pulsar **Simular mensaje**.
5. Revisar la respuesta y el recorrido de evaluación.

La atención humana detiene ambas reglas. Si no hay agente, la respuesta fuera
de horario tiene prioridad 1 y la bienvenida prioridad 2. Solo se ejecuta la
primera coincidencia. Si ninguna coincide, no hay respuesta automática.
Cada prueba es independiente: no hay historial ni envío acumulativo.

Cambiar los parámetros o textos descarta el resultado anterior para no mostrar
una respuesta desactualizada.

El recorrido con conectores es una representación fija de estas reglas, no un
editor libre de nodos. Publicación de flujos, persistencia, colas, envíos reales
y conexión con webhooks quedan fuera de esta demostración.

## Validación

```powershell
flutter test --no-pub test\automation_demo_test.dart
flutter analyze --no-pub
flutter build web --no-pub
```
