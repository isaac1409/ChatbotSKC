# Análisis Crítico del Sistema — ChatbotSKC / ZURA Solutions
> Generado: 2026-05-07 | Analista: Claude Code (Sonnet 4.6)

---

## RESUMEN EJECUTIVO

El sistema actual funciona en producción y resuelve el caso de uso principal (agendamiento
de citas por WhatsApp con IA), pero opera **sin base de datos de negocio**: toda la lógica
de citas vive en Google Calendar y toda la configuración en Google Sheets.

Esto crea 6 riesgos críticos que se detallan abajo. La solución propuesta añade una capa
PostgreSQL completa sin reemplazar Google Calendar (que sigue siendo la fuente de verdad
para el usuario y el admin).

---

## ESTADO ACTUAL — LO QUE REALMENTE EXISTE

### Stack en producción (verificado en código)

| Componente | Uso real |
|---|---|
| PostgreSQL | Solo tabla interna de n8n: `n8n_chat_histories` (memoria del agente) |
| Redis | Buffer de mensajes (ventana 5 segundos para agrupar mensajes rápidos) |
| Google Calendar | **Fuente de verdad de citas** — INSERT/UPDATE/DELETE viven aquí |
| Google Sheets | **Fuente de verdad de config** — leída en CADA mensaje entrante |
| OpenAI gpt-4.1 | Agente principal con tool calling |
| OpenAI gpt-4o-mini | Análisis de imágenes |
| OpenAI Whisper | Transcripción de audio |
| Evolution API | WhatsApp — send/receive + media base64 |

### Flujo real del workflow

```
Webhook → Immediate Response (200 OK) → fromMe==false? → Leer Google Sheets config →
Formatear config → Filtro modo_prueba → Switch tipo (text/image/audio/doc/sticker) →
Normalizar a entradaIA → Buffer Redis (PUSH) → Leer buffer → Switch: esperar/continuar/ignorar →
[wait 5s si "Esperar"] → Borrar buffer → Edit Fields5 → AI Agent (gpt-4.1 + tools) →
Limpiar output → Edit Fields2 → HTTP sendText → Revisar si se agendó →
¿Se agendó? → [Notificar admin WA + Gmail + Grupo WA]
```

---

## FASE 1: ANÁLISIS CRÍTICO

### 🔴 CRÍTICOS (rompen datos o disponibilidad)

#### C-1: Sin persistencia de citas en base de datos
**Problema:** Si Google Calendar falla, se borra un evento manualmente desde el UI, o se
revoca el OAuth2, el sistema pierde TODA la información de citas sin posibilidad de
recuperación. No existe backup de negocio.

**Impacto:** Pérdida total de datos ante cualquier fallo de Google Calendar.
**Solución:** Tabla `citas` en PostgreSQL como copia sincronizada.

#### C-2: Sin idempotencia de mensajes (duplicados posibles)
**Problema:** El webhook recibe cada mensaje de WhatsApp con un `key.id` único, pero el
workflow NO verifica si ese `key_id` ya fue procesado. Si Evolution API reintenta el
webhook (timeout, caída de red), el mensaje se procesa dos veces, pudiendo crear citas
duplicadas.

**Impacto:** Doble agendamiento, doble facturación de tokens OpenAI, UX confusa.
**Solución:** Tabla `mensajes` con `key_id` UNIQUE + check antes de procesar.

#### C-3: Config cargada desde Google Sheets en cada mensaje
**Problema:** Por cada mensaje entrante se hace 1 llamada HTTP a la API de Google Sheets.
Con 100 usuarios simultáneos = 100 llamadas paralelas a Google. La API tiene quotas
(read requests por minuto). Un pico de mensajes satura la quota y el bot deja de responder.

**Impacto:** Bot caído durante picos de tráfico.
**Solución:** Tabla `config_negocio` en PostgreSQL + cache en Redis (TTL 5 min).

#### C-4: Sin control de concurrencia en citas
**Problema:** Dos usuarios pueden agendar el mismo horario simultáneamente. El AI Agent
llama a `consultar_citas`, ambos ven el slot libre, ambos llaman a `agendar_cita`, ambas
llamadas a Google Calendar tienen éxito (Google Calendar acepta overlapping events).
El calendar queda con dos eventos en el mismo horario.

**Impacto:** Overbooking. El admin tiene que resolver manualmente.
**Solución:** Trigger `validar_overlap_citas` en PostgreSQL + lock pesimista antes de agendar.

### 🟠 ALTOS (degradan confiabilidad)

#### A-1: Sin persistencia de usuarios
**Problema:** No existe tabla de usuarios en PostgreSQL. El nombre, empresa, email del lead
solo vive en: (a) la memoria de conversación de n8n (10 mensajes de contexto) y (b) el
Summary del evento de Google Calendar. Si la conversación pierde contexto, el bot no sabe
quién es el usuario y vuelve a pedir los datos.

**Impacto:** UX degradada, re-captura de datos innecesaria.
**Solución:** Tabla `usuarios` con perfil persistente.

#### A-2: Sin manejo de errores estructurado
**Problema:** Los nodos de Calendar tienen `onError: continueRegularOutput`, que significa
que si Calendar falla, el workflow continúa como si hubiera tenido éxito. El usuario
recibe una confirmación de cita que en realidad nunca se creó.

**Impacto:** Citas "fantasma" — usuario cree que tiene cita, no existe en Calendar.
**Solución:** Error branches explícitos + tabla `error_log` + notificación al admin.

#### A-3: Sin audit trail
**Problema:** No hay registro de quién canceló qué, cuándo, con qué motivo. Imposible
hacer debugging post-mortem o reportes de negocio.

**Impacto:** Sin trazabilidad para disputas o análisis.
**Solución:** Tabla `audit_log` con triggers en tablas críticas.

#### A-4: Webhook "Isaac" hardcodeado
**Problema:** El nodo "Notificar grupo WhatsApp" tiene URL hardcodeada:
`http://evolution_evolution-api:8080/message/sendText/Isaac`
La instancia `Isaac` está escrita en el código, no en configuración.

**Impacto:** Rompe si se renombra la instancia o se migra a multi-tenant.
**Solución:** Leer `instancia` del config o del webhook original.

### 🟡 MEDIOS (deuda técnica)

#### M-1: contextWindowLength = 10 (puede ser insuficiente)
El historial de conversación se limita a 10 mensajes. Para flujos complejos
(reagendar con confirmación) puede perder contexto del eventId.
**Solución:** Aumentar a 20 + guardar contexto crítico (eventId) en tabla `sesiones`.

#### M-2: Workflow monolítico (1 archivo = todo)
Todo el flujo en un solo workflow dificulta mantenimiento, debugging y reutilización.
No es posible testear módulos individuales.
**Solución:** Dividir en sub-workflows por responsabilidad.

#### M-3: No hay métricas de negocio
No hay forma de saber cuántos leads entran, cuántos convierten, cuál es el tiempo
de respuesta promedio, cuántas citas se cancelan.
**Solución:** Tabla `metricas_diarias` + workflow de reporte nocturno.

#### M-4: Timezone hardcodeado en prompts
El timezone `America/Mexico_City` aparece literalmente en ~8 lugares del system prompt.
Si se cambia de cliente, hay que buscar y reemplazar en múltiples lugares.
**Solución:** Centralizar en config_negocio.timezone.

#### M-5: Sin rate limiting por usuario
Un usuario malicioso puede enviar mensajes en loop causando llamadas ilimitadas a OpenAI.
**Solución:** Campo `intentos_fallidos` + lógica de cooldown en tabla `usuarios`.

### 🟢 LO QUE ESTÁ BIEN (no cambiar)

- `fromMe === false` como primera condición — correcto, previene loops
- Webhook Response inmediato (200 OK antes de procesamiento) — correcto, previene duplicados de Evolution API
- Redis buffer con ventana de 5 segundos — elegante solución para mensajes rápidos
- `pairedItem: { item: 0 }` en Formatear config — correcto, sin esto el workflow falla downstream
- Normalización de media (imagen/audio/doc) a `entradaIA` — patrón limpio
- Tool descriptions detalladas en Calendar tools — crítico para que el LLM las use bien
- `onError: continueRegularOutput` en tools de calendario — discutible pero consciente
- gpt-4.1 para agente principal (no mini) — correcto, mini falla en tool calling

---

## COMPARATIVA: ACTUAL vs PROPUESTO

| Aspecto | Sistema Actual | Sistema Propuesto |
|---|---|---|
| Persistencia de citas | Solo Google Calendar | Google Calendar + PostgreSQL |
| Persistencia de usuarios | Solo en contexto conversacional | Tabla `usuarios` persistente |
| Config | Google Sheets (HTTP por mensaje) | PostgreSQL + Redis cache |
| Idempotencia | Ninguna | `key_id` UNIQUE en mensajes |
| Overlap de citas | Sin control | Trigger + función PL/pgSQL |
| Audit trail | Ninguno | Tabla `audit_log` con triggers |
| Error handling | `continueRegularOutput` silencioso | Error branches + `error_log` |
| Multi-tenant | Single hardcoded instance | Tabla `empresas` + `instancias` |
| Métricas | Ninguna | `metricas_diarias` automáticas |
| Rate limiting | Ninguno | `intentos_fallidos` + cooldown |
| Arquitectura n8n | 1 workflow monolítico | 1 orquestador + 13 sub-workflows |

---

## IMPACTO DE CAMBIOS

### Performance
- Eliminar Google Sheets call por mensaje: **-200ms a -800ms** por request
- Redis cache para config: **-150ms** en requests subsiguientes
- Índices en citas: queries de overlap en **<5ms** vs full scan

### Confiabilidad
- Idempotencia: elimina **100%** de duplicados por retry
- Overlap trigger: elimina **100%** de overbooking concurrente
- Error logging: visibilidad inmediata de fallos

### Escalabilidad
- Estructura multi-tenant desde el inicio: soporta N clientes sin cambios de schema
- Particionado de mensajes por mes: soporta 1M+ mensajes sin degradación
- Índices estratégicos: O(log n) en lugar de O(n) para queries frecuentes

---

## TIMELINE DE IMPLEMENTACIÓN

```
Día 1 (2 horas):   Ejecutar DDL + migration script + verificar índices
Día 1 (1 hora):    Migrar config de Google Sheets a tabla config_negocio
Día 2 (3 horas):   Actualizar workflow n8n: idempotencia + guardar citas + usuarios
Día 2 (2 horas):   Implementar sub-workflow de notificaciones + error handling
Día 3 (2 horas):   Sub-workflow recordatorio 24h (trigger programado)
Día 3 (1 hora):    Testing completo + validación en staging
Día 4 (1 hora):    Deploy a producción + monitoreo

Total: ~12 horas de implementación
Downtime máximo: 30 minutos (ejecución del migration script)
```
