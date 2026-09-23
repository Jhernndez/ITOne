# ITONE — Arquitectura empresarial y técnica

**Propietario:** IT DATA SAS  
**Producto:** ITONE  
**Versión del documento:** 1.0  
**Fecha:** 23 de septiembre de 2026  
**Estado:** Base de arquitectura para diseño detallado y desarrollo

> Este documento define la visión, límites, principios y decisiones de arquitectura de ITONE. No contiene código, tablas SQL, endpoints ni diseños de pantallas.

## 1. Visión general del producto

ITONE será una plataforma SaaS empresarial multitenant para coordinar operaciones, clientes, solicitudes, comunicaciones, automatización e información de negocio. Su propuesta no es ser un CRM, una mesa de ayuda ni una plataforma de WhatsApp aislada, sino una **plataforma de operaciones empresariales componible**.

Cada empresa operará en un tenant independiente, con sus propios usuarios, roles, datos, módulos, configuraciones, integraciones, marca y políticas. La plataforma debe permitir que una empresa de TI, un MSP, una IPS, un centro terapéutico, una consultora, una compañía de logística o una empresa de servicios utilice el mismo núcleo sin forzar procesos específicos de una industria.

### Principios de producto

1. **Configuración antes que personalización por código:** los procesos comunes deben resolverse mediante configuración, reglas y plantillas.
2. **Módulos activables:** un tenant solo debe ver y utilizar las capacidades contratadas y autorizadas.
3. **Seguridad por diseño:** el aislamiento por tenant se aplica en identidad, autorización, datos, archivos, eventos, integraciones, observabilidad y soporte.
4. **Operación centrada en el contexto:** clientes, contactos, solicitudes, conversaciones, actividades, contratos y evidencias deben poder relacionarse sin duplicar información.
5. **Automatización gobernada:** las reglas automáticas requieren permisos, trazabilidad, límites y manejo de errores.
6. **API e integración como producto:** las integraciones no deben depender de lógica exclusiva de una interfaz Flutter.
7. **Evolución portable:** Supabase acelera el lanzamiento inicial; el diseño debe evitar acoplamientos que impidan operar posteriormente sobre Azure.

### Resultados de negocio esperados

- Reducir la fragmentación entre CRM, soporte, comunicación y operación.
- Permitir que IT DATA SAS administre el catálogo, los tenants, los planes y la operación global.
- Permitir que cada tenant administre sus equipos, clientes y procesos sin afectar a otras empresas.
- Crear una base para ingresos recurrentes por módulos, usuarios, consumo e integraciones.
- Obtener trazabilidad operativa y regulatoria suficiente para sectores sensibles.

### Límites de esta fase

Quedan fuera de este documento la definición de pantallas, contratos de API, esquema físico de base de datos, consultas SQL, código, reglas fiscales específicas por país y especificaciones detalladas de cada industria. Esos artefactos deben derivarse posteriormente de esta arquitectura.

## 2. Arquitectura conceptual

### 2.1 Actores

- **IT DATA SAS:** operador de la plataforma, responsable del catálogo, facturación/plataforma, soporte global, seguridad y gobierno.
- **Administrador de tenant:** configura una empresa, sus usuarios, módulos, marca, integraciones y políticas.
- **Supervisor:** coordina equipos, colas, prioridades, SLA y calidad operativa.
- **Operador:** ejecuta actividades y atiende casos asignados.
- **Usuario final:** usuario interno del tenant que consulta o solicita servicios según sus permisos.
- **Cliente externo:** persona u organización que interactúa con el tenant mediante portal, correo, mensajería u otros canales.
- **Sistemas externos:** Meta, Microsoft 365, Google Workspace, proveedores de correo, servicios de identidad y APIs de terceros.

### 2.2 Capacidades de negocio

El núcleo de ITONE debe proporcionar capacidades transversales:

- Identidad, autenticación, sesiones y pertenencia a tenants.
- Administración de organizaciones, personas, contactos y relaciones.
- Catálogo de módulos, planes, entitlements y consumo.
- Gestión de casos de negocio: solicitudes, tickets, tareas, actividades y estados configurables.
- Comunicación omnicanal con trazabilidad.
- Reglas, automatizaciones, plantillas, colas y notificaciones.
- SLA, calendarios, prioridades y escalamiento.
- Archivos, evidencias y retención.
- Reportes, métricas y dashboards.
- Auditoría, seguridad, observabilidad y administración de la plataforma.

Los módulos de industria deben reutilizar estas capacidades en lugar de crear núcleos paralelos.

### 2.3 Objetos conceptuales principales

Sin definir todavía tablas, los conceptos que deben existir son:

- **Tenant:** límite de propiedad, seguridad, configuración, facturación y datos.
- **Workspace o unidad operativa:** agrupación opcional dentro de un tenant, como sede, área, cliente interno o línea de servicio.
- **Identity:** cuenta autenticable; puede pertenecer a uno o varios tenants según la política de producto.
- **Membership:** relación entre una identidad y un tenant, con roles, estado y contexto.
- **Party:** persona u organización que participa en una operación, interna o externa.
- **Case:** unidad de trabajo trazable; puede representar ticket, solicitud, incidente, oportunidad, visita o proceso de servicio.
- **Activity:** acción planificada o ejecutada sobre un caso, cliente o proceso.
- **Conversation:** intercambio de mensajes asociado a un tenant, canal y contexto de negocio.
- **Integration connection:** autorización y configuración de un proveedor externo perteneciente a un tenant.
- **Entitlement:** derecho efectivo a utilizar un módulo, función, capacidad o límite.
- **Audit event:** registro inmutable de una acción relevante.

## 3. Arquitectura lógica

Se recomienda iniciar con un **monolito modular bien delimitado**, acompañado por workers asíncronos y una capa de integraciones. No se recomienda comenzar con microservicios: el costo operativo, de observabilidad y de consistencia sería desproporcionado para un MVP.

### 3.1 Capas lógicas

1. **Canales de experiencia**
   - Flutter Web para usuarios internos y portales web.
   - Flutter Android e iOS para operación móvil.
   - Dominios personalizados y subdominios de ITONE.
   - Interfaces administrativas separadas conceptualmente, aunque inicialmente puedan compartir aplicación.

2. **Borde de plataforma**
   - Terminación TLS, CDN, protección contra abuso, límites de tráfico y resolución de tenant por host.
   - Validación de sesión y propagación segura del contexto de tenant.
   - No debe confiar en un `tenant_id` enviado por el cliente como prueba de pertenencia.

3. **Núcleo de aplicación**
   - Identidad y acceso.
   - Contexto de tenant y políticas de autorización.
   - Clientes y relaciones.
   - Casos, tareas y actividades.
   - SLA y reglas de negocio.
   - Comunicaciones y notificaciones.
   - Archivos.
   - Reportes y configuraciones.
   - Catálogo, suscripciones y entitlements.
   - Auditoría transversal.

4. **Orquestación y procesamiento asíncrono**
   - Cola de trabajos para mensajes, webhooks, automatizaciones, notificaciones, importaciones y reportes.
   - Reintentos con backoff, idempotencia, dead-letter queue y trazabilidad por operación.
   - Jobs programados para SLA, escalamiento, retención y sincronizaciones.

5. **Adaptadores de integración**
   - Meta WhatsApp Cloud API.
   - Correo transaccional.
   - Microsoft 365 y Google Workspace.
   - Proveedores de identidad.
   - APIs y webhooks de terceros.
   - Cada adaptador debe aislar credenciales, límites, formatos y errores del proveedor.

6. **Persistencia y plataforma**
   - PostgreSQL como fuente transaccional.
   - Almacenamiento de objetos para archivos y medios.
   - Cache para datos de lectura segura y corta duración.
   - Bus o cola para eventos y trabajos.
   - Observabilidad centralizada.

### 3.2 Organización interna del monolito modular

Cada módulo debe tener contratos internos explícitos, propiedad clara de sus datos, permisos, eventos de dominio y pruebas. Un módulo no debe leer directamente estructuras internas de otro módulo para saltarse sus reglas. Las dependencias recomendadas son:

- Identidad, tenant y autorización: base transversal.
- Clientes, catálogo y casos: núcleo de operación.
- SLA, automatizaciones, comunicaciones y dashboard: módulos dependientes del núcleo.
- Integraciones: capa adaptadora que consume contratos del núcleo.
- Auditoría y observabilidad: capacidades transversales invocadas por todos los módulos.

La futura extracción de servicios debe hacerse solo cuando exista una razón medible: escala independiente, aislamiento de fallos, límites de proveedor o equipos autónomos.

### 3.3 Modelo de autorización

Se recomienda combinar:

- **RBAC:** roles y permisos asignados por tenant.
- **Alcance contextual:** tenant, unidad, equipo, cola, caso o cliente.
- **Reglas de estado:** por ejemplo, quién puede cerrar, reabrir, exportar o modificar una conversación.
- **Entitlements:** si el tenant tiene contratado el módulo o capacidad.
- **Políticas de datos:** campos sensibles, archivos y acciones de alto riesgo.

Los roles iniciales son plantillas administrables, no permisos codificados de forma irreversible:

- **Super Administrador IT DATA:** gobierno global, soporte controlado y operación de tenants; no debe implicar acceso indiscriminado al contenido de clientes.
- **Administrador Tenant:** configuración completa dentro de su tenant.
- **Supervisor:** coordinación y supervisión de sus ámbitos operativos.
- **Operador:** ejecución de actividades y atención de trabajo asignado.
- **Usuario Final:** consumo de servicios internos según autorización.
- **Cliente Externo:** acceso limitado a sus propios datos, casos y conversaciones.

Debe existir soporte futuro para roles personalizados, delegación temporal, segregación de funciones y acceso de soporte con consentimiento y caducidad.

### 3.4 Auditoría y trazabilidad

La auditoría debe ser un servicio transversal, no una funcionalidad opcional de cada módulo. Debe registrar, según criticidad:

- Actor, tenant, sesión y correlación de operación.
- Fecha y zona horaria normalizada.
- Acción, recurso y resultado.
- IP, dispositivo y agente de cliente cuando estén disponibles.
- Valores relevantes antes/después, evitando secretos y datos innecesarios.
- Origen: interfaz, API, job, webhook o soporte.

Los eventos de auditoría deben ser append-only, con retención configurable por plan y exportación para investigación. La actividad de soporte de IT DATA debe diferenciarse de la actividad del personal del tenant.

## 4. Arquitectura física recomendada

### 4.1 Fase inicial: Supabase administrado

- Flutter consume una capa de aplicación segura; no se debe convertir el cliente en la única capa de negocio.
- Supabase se utiliza para PostgreSQL, autenticación, almacenamiento y capacidades administradas que sean adecuadas.
- Las políticas de seguridad a nivel de fila pueden complementar, pero no reemplazar, la autorización de aplicación.
- Los procesos sensibles y secretos se ejecutan en backend confiable o workers, nunca en Flutter.
- El almacenamiento de archivos debe usar rutas y políticas que incluyan tenant y controles de acceso.
- Backups, restauración puntual, retención y pruebas de recuperación deben estar definidos desde el primer entorno productivo.

### 4.2 Entornos

Como mínimo:

- Desarrollo individual.
- Integración/pruebas.
- Staging con configuración similar a producción.
- Producción.

Cada entorno debe tener proyectos, credenciales y datos separados. Nunca se deben probar webhooks o plantillas de producción con credenciales de desarrollo mezcladas.

### 4.3 Evolución hacia Azure

La arquitectura debe conservar una capa de abstracción para:

- PostgreSQL administrado: Supabase inicialmente, Azure Database for PostgreSQL en una fase posterior.
- Archivos: Supabase Storage inicialmente, Azure Blob Storage posteriormente.
- Jobs/eventos: servicio gestionado inicial, Azure Service Bus/Event Grid posteriormente.
- Secretos: vault gestionado; Azure Key Vault en la migración.
- Observabilidad: telemetría centralizada con posibilidad de Azure Monitor/Application Insights.
- CDN, WAF, DNS y certificados: proveedor inicial compatible con migración a Azure Front Door, WAF y DNS administrado.

La portabilidad no significa abstraer todos los proveedores desde el primer día; significa evitar que el dominio de negocio dependa directamente de SDKs o formatos de un proveedor.

### 4.4 Disponibilidad, recuperación y seguridad operacional

Antes del primer cliente productivo deben definirse RPO, RTO, retención, procedimiento de restauración, rotación de secretos, gestión de incidentes y responsables. La plataforma debe incluir:

- Cifrado en tránsito y en reposo.
- Gestión centralizada de secretos.
- MFA para roles privilegiados.
- Rate limiting y protección de webhooks.
- Alertas de errores, colas atascadas, fallos de integración y consumo anómalo.
- Separación estricta entre datos de aplicación, logs y respaldos.

## 5. Estrategia multitenant

### 5.1 Modelo recomendado

Comenzar con **base compartida y esquema compartido**, con `tenant_id` obligatorio en todo registro de negocio y controles de acceso aplicados consistentemente. Este modelo optimiza costo y operación para 100–1000 empresas, siempre que se acompañe de controles fuertes.

Cada tenant debe tener:

- Identidad de configuración y estado.
- Usuarios/memberships y políticas.
- Módulos y entitlements.
- Marca, idioma y zona horaria.
- Integraciones y secretos propios.
- Numeración, plantillas, calendarios y reglas propias.
- Cuotas, consumo y auditoría.

### 5.2 Aislamiento obligatorio

El contexto de tenant se determina en el servidor a partir de la sesión, membership y dominio; nunca desde un valor confiado del cliente. Debe validarse en:

- Consultas y comandos de aplicación.
- Políticas de PostgreSQL y acceso a objetos.
- Jobs asíncronos y eventos.
- Webhooks entrantes.
- Cache y claves de idempotencia.
- Exportaciones, reportes y búsquedas.
- Logs, métricas y soporte administrativo.

Los workers deben transportar explícitamente el tenant context y rechazar trabajos sin contexto válido. Los caches compartidos deben incluir tenant y versión de configuración en su clave.

### 5.3 Escalamiento del aislamiento

El modelo compartido es el punto de partida. Debe existir una ruta de aislamiento reforzado para tenants regulados o de alto volumen:

1. Compartido con políticas estrictas.
2. Esquema dedicado para un tenant.
3. Base de datos dedicada.
4. Proyecto/entorno dedicado cuando exista requisito contractual o regulatorio.

La selección debe ser una decisión comercial y técnica documentada, no una excepción manual imposible de operar.

### 5.4 Datos sensibles y cumplimiento

IPS y centros terapéuticos pueden manejar información sensible. Antes de comercializarlos deben definirse clasificación de datos, consentimiento, retención, derecho de acceso/eliminación, residencia, contratos de tratamiento y requisitos locales aplicables. ITONE no debe asumir que una autorización general de cliente permite procesar historia clínica o información terapéutica.

## 6. Estrategia de dominios

### 6.1 Subdominios de ITONE

Formato recomendado:

`<slug-tenant>.itone.itdata.com.co`

El slug debe ser único, normalizado, reservado y no reutilizable de forma que pueda romper enlaces históricos. La resolución de dominio debe mapear host a tenant mediante un registro administrado por plataforma, nunca por concatenación insegura.

### 6.2 Dominios personalizados

Se debe soportar un dominio por tenant en el MVP avanzado y múltiples dominios como capacidad posterior. El flujo debe incluir:

1. Solicitud del dominio por el administrador.
2. Verificación de propiedad mediante DNS.
3. Emisión y renovación automática del certificado TLS.
4. Activación solo después de verificación y configuración completa.
5. Asociación inequívoca dominio–tenant.
6. Posibilidad de revocación, cambio y período de gracia.

Ejemplos soportados: `portal.cliente.com`, `soporte.cliente.com`, `app.cliente.com`.

El dominio identifica experiencia y tenant; no debe otorgar permisos. La sesión y membership siguen siendo la fuente de autorización. Deben contemplarse cookies seguras, prevención de host-header injection, CORS por allowlist y protección contra takeover de dominios abandonados.

### 6.3 Marca y experiencia

La configuración de tenant debe controlar nombre, logo, colores, favicon, idioma, zona horaria, textos legales, firma de correo y módulos visibles. Los assets deben validarse, optimizarse y almacenarse aislados por tenant. Debe existir una marca de plataforma visible en áreas administrativas o legales cuando corresponda.

## 7. Estrategia de licenciamiento

### 7.1 Modelo comercial recomendado

Usar un modelo híbrido:

- Suscripción base por tenant.
- Módulos contratados.
- Límites incluidos por usuarios, almacenamiento, mensajes, automatizaciones o volumen.
- Add-ons para capacidad adicional.
- Consumo medido para servicios costosos como WhatsApp, IA y procesamiento intensivo.

La facturación puede iniciar manualmente o con un proveedor externo, pero el producto debe tener desde el comienzo un catálogo interno de planes, módulos, precios, estados y entitlements.

### 7.2 Entitlement como fuente de verdad

La habilitación efectiva debe calcularse a partir de:

- Plan contratado.
- Add-ons.
- Fecha de inicio y vencimiento.
- Estado de pago o suspensión.
- Límites y consumo.
- Flags operativos controlados por IT DATA.

No se debe proteger un módulo únicamente ocultando un botón en Flutter. La verificación debe ocurrir en la autorización del backend, en jobs y en acceso a datos. Los cambios de plan deben ser auditables, idempotentes y con reglas de gracia.

### 7.3 Separación de conceptos

- **Módulo:** capacidad funcional, por ejemplo Tickets.
- **Feature:** función dentro de un módulo, por ejemplo SLA por calendario.
- **Entitlement:** derecho efectivo de un tenant.
- **Quota:** límite cuantitativo.
- **Meter:** medición de consumo.
- **Plan:** conjunto comercial de módulos, límites y precio.

Esta separación evita que cambios de precios obliguen a modificar la lógica del dominio.

## 8. Estrategia de módulos

### 8.1 Módulos propuestos

- **Plataforma y administración:** tenants, usuarios, roles, marca, configuración, auditoría y soporte.
- **Clientes y relaciones:** organizaciones, contactos, activos, contratos y relaciones.
- **Casos y tickets:** solicitudes, incidentes, estados, prioridades, colas, asignaciones y evidencias.
- **SLA y operación:** calendarios, horarios, pausas, objetivos, escalamiento y cumplimiento.
- **Comunicaciones:** correo, WhatsApp, notificaciones y conversaciones.
- **Automatizaciones:** disparadores, condiciones, acciones, aprobaciones y jobs.
- **API e integraciones:** conexiones, credenciales, webhooks, sincronización y logs.
- **Dashboards y analítica:** métricas operativas, tableros configurables y exportaciones.
- **Anuncios:** comunicaciones masivas controladas dentro del tenant.
- **IA:** asistencia, clasificación, resumen y sugerencias con controles de privacidad y consumo.

### 8.2 Reglas de diseño modular

- Cada módulo declara dependencias, permisos, eventos, configuración, métricas y límites.
- La desactivación debe tener comportamiento definido: ocultar, bloquear nuevas operaciones, conservar lectura o permitir exportación.
- Los datos no deben eliminarse automáticamente al desactivar un módulo.
- Las funciones de alto costo deben estar detrás de cuotas y observabilidad.
- Los módulos verticales futuros deben componerse sobre Clientes, Casos, Actividades, Archivos, Comunicaciones y Automatizaciones.

## 9. Estrategia de WhatsApp multitenant

### 9.1 Modelo de conexión

Cada tenant debe registrar su propia conexión Meta, con sus identificadores, números, Business Manager, credenciales, plantillas, políticas y estado. ITONE no debe usar una credencial global para enviar mensajes como distintos clientes.

Las credenciales y tokens:

- Se almacenan cifrados y nunca se exponen a Flutter.
- Tienen rotación, expiración, revocación y estado de salud.
- Se identifican por tenant y cuenta/número.
- Se muestran enmascarados en administración y auditoría.
- Se prueban con un flujo de conexión y validación controlado.

### 9.2 Webhooks

La recepción debe ser segura y enrutable para múltiples tenants:

- Verificación inicial de Meta.
- Identificación de cuenta/número mediante datos del proveedor y mapeo interno.
- Validación de firma y protección contra replay cuando aplique.
- Persistencia del evento recibido con idempotencia.
- Encolamiento para procesamiento asíncrono.
- Respuesta rápida al proveedor, sin ejecutar lógica pesada en la solicitud entrante.
- Rechazo explícito de eventos sin mapeo válido; nunca asignarlos a un tenant por defecto.

Puede utilizarse un endpoint de recepción compartido con enrutamiento seguro o endpoints por conexión; la decisión debe priorizar operación, trazabilidad y límites del proveedor. La seguridad no puede depender solo de la URL.

### 9.3 Mensajería y plantillas

Cada mensaje debe conservar tenant, conexión, número, conversación, dirección, estado del proveedor, correlación de caso y referencia de plantilla. Las plantillas deben tener:

- Estado de aprobación de Meta.
- Idioma y versión.
- Parámetros validados.
- Restricciones por tipo de mensaje.
- Auditoría de cambios.

El motor de envío debe ser idempotente, respetar ventanas y políticas de Meta, aplicar rate limits por tenant y conexión, manejar reintentos sin duplicar mensajes y registrar fallos de entrega.

### 9.4 Flujos y automatizaciones

Los flujos de WhatsApp deben pertenecer al tenant y usar únicamente conexiones, plantillas, datos y reglas autorizadas de ese tenant. Deben incluir límites de ejecución, prevención de ciclos, aprobación para campañas y trazabilidad completa.

WhatsApp no debe convertirse en el modelo de negocio principal: la conversación debe poder vincularse con cliente, caso, actividad, SLA y automatización.

## 10. Riesgos técnicos y mitigaciones

| Riesgo | Impacto | Mitigación recomendada |
|---|---|---|
| Fuga de datos entre tenants | Crítico | Contexto de tenant server-side, políticas de base de datos, pruebas negativas automatizadas, revisión de cache/jobs/exportaciones. |
| Confianza excesiva en Flutter | Alto | Backend como autoridad de autorización y reglas; cliente solo como consumidor. |
| Complejidad prematura de microservicios | Alto | Monolito modular, colas y contratos internos; extraer solo con métricas. |
| Tokens de Meta expuestos o mezclados | Crítico | Vault/cifrado, acceso backend, conexión por tenant, rotación y auditoría. |
| Duplicación de webhooks/mensajes | Alto | Idempotencia, claves únicas conceptuales, estados de entrega y reintentos controlados. |
| Dependencia de Supabase | Medio/alto | Adaptadores, contratos de dominio, backups exportables y plan de migración probado. |
| Dominios personalizados mal configurados | Alto | Verificación DNS, certificados gestionados, allowlists y protección de takeover. |
| Datos sensibles sin gobierno | Crítico | Clasificación, minimización, retención, consentimiento y aislamiento reforzado antes de sectores regulados. |
| Automatizaciones en bucle o costosas | Alto | Límites, timeouts, deduplicación, circuit breakers, cuotas y dead-letter queue. |
| Auditoría incompleta o manipulable | Alto | Servicio append-only, acceso restringido, correlación y alertas de integridad. |
| Dashboards que degradan transacciones | Medio/alto | Lecturas agregadas, réplicas o almacén analítico cuando el volumen lo justifique. |
| Personalización que genera forks | Medio | Configuración declarativa, catálogo de extensiones y gobernanza de cambios. |
| Soporte global con acceso excesivo | Alto | Just-in-time access, consentimiento, motivo, caducidad, auditoría y enmascaramiento. |
| Costos impredecibles de IA/WhatsApp | Medio/alto | Meters, cuotas, presupuesto por tenant, alertas y apagado seguro. |

## 11. Decisiones técnicas recomendadas

1. **Arquitectura inicial:** monolito modular con workers asíncronos; no microservicios en el MVP.
2. **Persistencia:** PostgreSQL como sistema transaccional principal.
3. **Proveedor inicial:** Supabase para acelerar autenticación, PostgreSQL y almacenamiento, con encapsulación de proveedor.
4. **Cliente:** Flutter Web, Android e iOS compartiendo dominio funcional, con capacidades específicas por plataforma cuando sea necesario.
5. **Multitenancy:** esquema compartido con tenant context obligatorio y políticas de defensa en profundidad.
6. **Autorización:** RBAC + alcance contextual + entitlements + reglas de estado.
7. **Asincronía:** cola gestionada desde la primera integración externa relevante.
8. **Secretos:** nunca en cliente; almacenamiento administrado, cifrado y rotación.
9. **WhatsApp:** conexión y credenciales por tenant; webhooks idempotentes y procesamiento asíncrono.
10. **Dominios:** subdominio gestionado por ITONE desde el inicio; custom domains como capacidad planificada con verificación y TLS automatizado.
11. **Auditoría:** transversal, append-only, con política de retención y acceso restringido.
12. **Configuración:** feature/entitlement centralizado, no flags dispersos por pantalla.
13. **Observabilidad:** logs estructurados, métricas por tenant sin filtrar datos sensibles y trazas correlacionadas.
14. **Migración Azure:** definir contratos de infraestructura y exportación/recuperación antes de necesitar la migración.
15. **Calidad:** pruebas de aislamiento tenant, autorización, idempotencia, recuperación y cargas representativas como criterios de salida.

## 12. Roadmap técnico de alto nivel

### Fase 0 — Fundación y decisiones

- Validar modelo comercial, sectores objetivo y clasificación de datos.
- Confirmar requisitos legales, privacidad, retención y residencia.
- Definir ADRs, estrategia de entornos, observabilidad, backup y recuperación.
- Establecer el catálogo inicial de módulos y planes.

### Fase 1 — Plataforma base

- Tenants, identidades, memberships, roles, permisos y auditoría.
- Configuración, branding, idioma, zona horaria y dominios internos.
- Núcleo de clientes, relaciones, casos, actividades y archivos.
- Entitlements y administración de módulos.

### Fase 2 — Operación MVP

- Tickets/casos, colas, asignaciones, prioridades y estados.
- SLA básico, calendarios y escalamiento.
- Notificaciones y correo transaccional.
- Dashboards operativos iniciales y exportación controlada.

### Fase 3 — WhatsApp e integraciones

- Conexión Meta por tenant.
- Webhooks, conversaciones, plantillas, envío, recepción y estados.
- Automatizaciones iniciales y API/integraciones base.
- Gestión de dominios personalizados.

### Fase 4 — Madurez empresarial

- Roles personalizados, segregación de funciones y soporte just-in-time.
- Microsoft 365, Google Workspace y sincronizaciones.
- Anuncios, dashboards configurables, métricas de consumo y facturación más automatizada.
- Pruebas de carga, recuperación y aislamiento reforzado por tenant.

### Fase 5 — Escala y especialización

- Almacén analítico o réplicas de lectura.
- Separación selectiva de componentes de alto volumen.
- IA gobernada, capacidades verticales y despliegue progresivo sobre Azure.
- Opciones de base/esquema dedicado para clientes regulados o enterprise.

## 13. Épicas para desarrollo

1. Gobierno de producto, tenants y configuración global.
2. Identidad, autenticación, memberships y RBAC.
3. Seguridad, privacidad, auditoría y cumplimiento.
4. Branding, localización, zonas horarias y configuración del tenant.
5. Clientes, organizaciones, contactos y relaciones.
6. Casos, tickets, actividades, colas y asignaciones.
7. SLA, calendarios, prioridades, escalamiento y métricas.
8. Archivos, evidencias, retención y exportaciones.
9. Notificaciones y comunicación transaccional.
10. WhatsApp Cloud API multitenant.
11. Plantillas, conversaciones y trazabilidad omnicanal.
12. Automatizaciones, reglas, jobs, reintentos y aprobaciones.
13. API, webhooks, integraciones y gestión de credenciales.
14. Dashboards, reportes y analítica operativa.
15. Anuncios y comunicaciones masivas gobernadas.
16. Catálogo, planes, entitlements, cuotas, meters y facturación.
17. Dominios internos y dominios personalizados.
18. Observabilidad, soporte, incidentes y operación de la plataforma.
19. Escalabilidad, performance, backups y recuperación.
20. IA empresarial con privacidad, límites, evaluación y trazabilidad.

## 14. Módulos mínimos para un MVP

El MVP debe demostrar valor operativo sin intentar cubrir todos los sectores:

1. **Plataforma y administración**
   - Tenant, usuarios, membresías, roles iniciales, configuración, branding y auditoría.
2. **Clientes y contactos**
   - Organizaciones, personas, contactos y relación con operaciones.
3. **Casos/tickets**
   - Creación, estados, prioridades, asignación, comentarios, actividades y archivos.
4. **SLA básico**
   - Calendario, objetivos, vencimientos y escalamiento básico.
5. **Notificaciones**
   - Correo transaccional y notificaciones internas.
6. **Dashboard operativo**
   - Volumen, estado, tiempos y cumplimiento esencial.
7. **Licenciamiento**
   - Catálogo mínimo, activación de módulos, cuotas y estado de tenant.
8. **WhatsApp**
   - Solo si es requisito comercial de lanzamiento: una conexión por tenant en la primera versión, dejando el modelo preparado para múltiples conexiones, con recepción, envío controlado, plantillas aprobadas y trazabilidad.

Automatizaciones complejas, IA, anuncios masivos, múltiples conexiones por tenant, sincronizaciones profundas y capacidades verticales deben entrar después de validar el núcleo.

## 15. Recomendaciones para 100, 500 y 1000 empresas

### Hasta 100 empresas

- Mantener monolito modular y PostgreSQL compartido.
- Usar servicios administrados para reducir carga operativa.
- Automatizar onboarding, configuración de módulos y backups.
- Ejecutar pruebas de aislamiento y autorización en cada entrega.
- Medir por tenant: usuarios, casos, almacenamiento, mensajes, jobs y errores.

### Hasta 500 empresas

- Separar workers por tipo de carga y aplicar prioridades por tenant/plan.
- Implementar cuotas, rate limits y fairness para evitar noisy neighbors.
- Introducir cache controlado y lecturas agregadas para dashboards.
- Añadir réplica de lectura o almacén de reporting si las consultas analíticas afectan transacciones.
- Formalizar SLOs, guardias, gestión de incidentes y pruebas de restauración.
- Evaluar aislamiento de esquema o base para clientes grandes, regulados o contractualmente exigentes.

### Hasta 1000 empresas

- Mantener el núcleo modular, pero extraer selectivamente mensajería, procesamiento de webhooks, reporting y automatizaciones si sus perfiles de escala lo justifican.
- Usar colas particionadas, idempotencia y límites por tenant para WhatsApp y jobs.
- Adoptar observabilidad de capacidad, pruebas de carga multi-tenant y planificación de particionamiento/archivado.
- Migrar gradualmente infraestructura crítica a Azure cuando el costo, disponibilidad, compliance o control operativo lo justifique.
- Considerar pools o bases dedicadas para tenants de alto volumen, manteniendo un plano de control común.
- Definir onboarding automatizado, provisionamiento, migraciones versionadas y rollback operativo.
- Medir costos unitarios por tenant y por módulo para proteger margen bruto.

### Métricas de capacidad que deben gobernar las decisiones

No se debe dimensionar solo por número de empresas. Deben medirse al menos:

- Usuarios activos y concurrencia.
- Casos creados y actualizados por minuto.
- Mensajes entrantes/salientes y picos de webhook.
- Jobs por minuto y duración de automatizaciones.
- Almacenamiento y crecimiento de archivos.
- Latencia p95/p99 de operaciones críticas.
- Tasa de errores y trabajos en dead-letter queue.
- Tiempo y éxito de restauración.
- Costo de infraestructura por tenant, usuario y módulo.

## Criterio de cierre de esta fase

Antes de comenzar desarrollo debe aprobarse, como mínimo:

- Modelo de tenant y límites de acceso.
- Catálogo de módulos MVP y dependencias.
- Roles iniciales y matriz de permisos.
- Modelo de conexión WhatsApp y responsabilidades de Meta/ITONE/tenant.
- Política de datos sensibles y soporte.
- SLOs iniciales, backup, RPO/RTO y observabilidad.
- Modelo de licenciamiento y entitlements.
- Estrategia de dominios y certificados.
- Roadmap y criterios de entrada/salida por fase.

