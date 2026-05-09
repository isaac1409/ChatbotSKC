# Plan de Rollout — Sistema Optimizado ChatbotSKC
> Fecha objetivo: 2026-05-08 | Downtime máximo: 30 minutos

---

## PREREQUISITOS (completar antes de empezar)

- [ ] Backup completo de PostgreSQL ejecutado y verificado
- [ ] Backup de Google Calendar (export .ical)
- [ ] Credenciales de PostgreSQL disponibles
- [ ] Acceso SSH o consola a Easypanel
- [ ] n8n admin access confirmado
- [ ] Google Sheets abierta para copiar valores de config

---

## DÍA 1 — BASE DE DATOS (2.5 horas)

### Paso 1.1: Ejecutar DDL (30 min) — PRODUCCIÓN ACTIVA ✅

Las tablas nuevas no afectan el workflow existente. Se puede ejecutar con n8n corriendo.

```bash
# Conectarse a PostgreSQL desde Easypanel o psql directo
psql -U postgres -d <nombre_bd> -c "SELECT version();"

# Verificar extensiones disponibles
psql -U postgres -d <nombre_bd> -c "SELECT * FROM pg_available_extensions WHERE name IN ('pgcrypto','btree_gist');"

# Ejecutar DDL
psql -U postgres -d <nombre_bd> -f docs/sql/01_schema_ddl.sql 2>&1 | tee migration_ddl.log

# Verificar que no hay ERRORs en el log
grep -i error migration_ddl.log
```

**Validación:**
```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('empresas','usuarios','citas','sesiones','mensajes','config_negocio')
ORDER BY table_name;
-- Debe retornar 6 filas
```

### Paso 1.2: Crear triggers y funciones (15 min)

```bash
psql -U postgres -d <nombre_bd> -f docs/sql/03_triggers.sql 2>&1 | tee migration_triggers.log
psql -U postgres -d <nombre_bd> -f docs/sql/04_functions.sql 2>&1 | tee migration_functions.log
```

### Paso 1.3: Actualizar config_negocio con valores reales (20 min)

Copiar valores actuales de Google Sheets a la BD:

```sql
UPDATE config_negocio SET valor = 'NUMERO_REAL_DEL_ADMIN'
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
  AND campo = 'numero_admin';

UPDATE config_negocio SET valor = 'correo_real@gmail.com'
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
  AND campo = 'correo_admin';

UPDATE config_negocio SET valor = 'GRUPO_REAL_ID'
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
  AND campo = 'grupo_whatsapp';

-- Agregar businessInfo (info del negocio que estaba en Google Sheets)
INSERT INTO config_negocio (empresa_id, campo, valor)
VALUES
    ('a0000000-0000-0000-0000-000000000001', 'descripcion', 'Agencia de desarrollo de software...'),
    ('a0000000-0000-0000-0000-000000000001', 'servicios_principales', 'Sitios web, landing pages, IA...')
ON CONFLICT (empresa_id, campo) DO UPDATE SET valor = EXCLUDED.valor;
```

**Validación:**
```sql
SELECT campo, valor FROM config_negocio
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
ORDER BY campo;
-- Verificar que ningún valor diga 'REEMPLAZAR_CON_...'
```

### Paso 1.4: Ejecutar migration de usuarios desde historial (15 min)

```bash
psql -U postgres -d <nombre_bd> -f docs/sql/05_migration.sql 2>&1 | tee migration_data.log
```

**Validación:**
```sql
SELECT COUNT(*) FROM usuarios; -- Debe ser > 0 si había historial en n8n_chat_histories
SELECT COUNT(*) FROM sesiones;
```

### Paso 1.5: Crear índices CONCURRENTLY (20 min) — sin bloqueos

```bash
# IMPORTANTE: ejecutar fuera de transacción (no en BEGIN/COMMIT)
psql -U postgres -d <nombre_bd> -f docs/sql/02_indexes.sql 2>&1 | tee migration_indexes.log
```

### Paso 1.6: Ejecutar test suite (10 min)

```bash
# SOLO en staging/desarrollo, NO en producción con datos reales
psql -U postgres -d <nombre_bd_staging> -f docs/sql/06_test_fixtures.sql 2>&1 | tee test_results.log
grep -E "PASÓ|FALLÓ|WARNING" test_results.log
```

---

## DÍA 2 — ACTUALIZAR WORKFLOW N8N (3 horas) — REQUIERE DOWNTIME 30 MIN

### Paso 2.1: Preparación (sin downtime)

1. Clonar el workflow actual en n8n como backup:
   - n8n UI → Workflow → botón "..." → Duplicate
   - Renombrar la copia: `Chatbot_Isaac_BACKUP_20260508`

2. Exportar el workflow actual:
   - Settings → Download → guardar como `Chatbot_Isaac_v_antes_migracion.json`
   - Mover a `workflows/` con git commit

### Paso 2.2: ⚠️ DOWNTIME START — Deshabilitar webhook (2 min)

```
n8n UI → Workflow activo → Toggle OFF (deshabilitar)
```

> Ahora los mensajes de WhatsApp llegan pero no se procesan (Evolution API retiene o descarta).
> **Máximo 30 minutos en este estado.**

### Paso 2.3: Agregar nodos de idempotencia al workflow (20 min)

Añadir ANTES del nodo `If` (fromMe):

**Nodo nuevo: "Verificar mensaje procesado"** (Postgres node)
```sql
SELECT id FROM mensajes WHERE key_id = '{{ $json.body.data.key.id }}' LIMIT 1
```

**Nodo nuevo: "IF duplicado"** (If node)
```
condition: $json.length > 0  (si retornó filas = duplicado)
true: No Action
false: continuar
```

**Nodo nuevo: "Registrar mensaje entrada"** (Postgres node)
```sql
INSERT INTO mensajes (empresa_id, key_id, direccion, tipo, contenido, metadata)
SELECT
    e.id,
    '{{ $json.body.data.key.id }}',
    'entrada',
    'texto',
    '{{ $json.body.data.message.conversation }}',
    '{"instance": "{{ $json.body.instance }}"}'::jsonb
FROM instancias_whatsapp i
JOIN empresas e ON i.empresa_id = e.id
WHERE i.evolution_instance_name = '{{ $json.body.instance }}'
ON CONFLICT (key_id) DO NOTHING
RETURNING id
```

### Paso 2.4: Reemplazar Google Sheets con Postgres config (20 min)

**Eliminar nodo:** `Leer config negocio` (Google Sheets)

**Agregar nodo:** "Cargar config empresa" (Postgres)
```sql
SELECT get_config_empresa(
    (SELECT empresa_id FROM instancias_whatsapp
     WHERE evolution_instance_name = '{{ $('Webhook').first().json.body.instance }}'
     LIMIT 1)
)
```

**Actualizar nodo:** `Formatear config`
```javascript
// Cambiar para leer desde Postgres en lugar de Google Sheets
const config = $input.first().json.get_config_empresa;

// El resto del código permanece igual, solo cambia la fuente
const {
    numero_admin, correo_admin, grupo_whatsapp, modo_prueba,
    horario_inicio, horario_fin, duracion_reunion,
    nombre_agente, nombre_empresa
} = config;

// Construir businessInfo desde campos dinámicos de config
const RESERVADOS = new Set([...]);
const parts = [];
for (const [key, val] of Object.entries(config)) {
    if (!RESERVADOS.has(key) && val) parts.push(`${key}: ${val}`);
}
const businessInfo = parts.join('\n');

return [{ json: { ...config, businessInfo }, pairedItem: { item: 0 } }];
```

### Paso 2.5: Agregar sincronización de citas (15 min)

Después del nodo `Revisar si se agendó`, cuando `tipoEvento != 'ninguno'`:

**Agregar nodo:** "Sync cita en BD" (Postgres)
```sql
SELECT CASE
    WHEN '{{ $json.tipoEvento }}' = 'nueva' THEN
        registrar_cita(
            (SELECT empresa_id FROM instancias_whatsapp
             WHERE evolution_instance_name = '{{ $('Webhook').first().json.body.instance }}'
             LIMIT 1),
            (SELECT id FROM usuarios WHERE numero_limpio = '{{ $('Edit Fields5').first().json.number }}'
             AND empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = '{{ $('Webhook').first().json.body.instance }}' LIMIT 1)
             LIMIT 1),
            '{{ $json.citaAgendada.event_id }}',
            'contacto.skcia@gmail.com',
            '{{ $json.citaAgendada.summary }}',
            '{{ $json.citaAgendada.start }}'::timestamptz,
            '{{ $json.citaAgendada.end }}'::timestamptz,
            '{{ $json.citaAgendada.description }}'
        )::text
    WHEN '{{ $json.tipoEvento }}' = 'cancelada' THEN
        cancelar_cita_bd('{{ $json.eventoCancelado.id }}', 'cancelada por usuario')::text
END AS resultado
```

### Paso 2.6: ⚠️ DOWNTIME END — Reactivar workflow (2 min)

```
n8n UI → Workflow → Toggle ON
```

> **FIN DEL DOWNTIME** — El sistema está activo con las mejoras aplicadas.

### Paso 2.7: Validación post-deploy (10 min)

```
1. Enviar un mensaje de prueba al chatbot desde el número de admin
2. Verificar en PostgreSQL que el mensaje quedó registrado:
   SELECT * FROM mensajes ORDER BY created_at DESC LIMIT 5;

3. Agendar una cita de prueba
4. Verificar en PostgreSQL:
   SELECT * FROM citas ORDER BY created_at DESC LIMIT 5;

5. Verificar que la config cargó desde Postgres (no Google Sheets):
   Revisar logs de n8n para el nodo "Cargar config empresa"
```

---

## DÍA 3 — SUB-WORKFLOW DE RECORDATORIOS (2 horas)

### Paso 3.1: Crear workflow `Chatbot_Recordatorio_24h`

1. n8n → New Workflow → nombrar `Chatbot_Recordatorio_24h`
2. Agregar los nodos según la arquitectura en `docs/n8n/WORKFLOW_ARCHITECTURE.md`
   Sección: **SUB-MÓDULO H: CONFIRMACIÓN AUTOMÁTICA 24H**
3. Configurar Cron: `0 9 * * 1-5` (9:00 AM Lunes-Viernes)
4. Activar el workflow

**Validación:**
```sql
-- Verificar que hay citas próximas para testear el recordatorio
SELECT * FROM v_proximas_citas WHERE inicio < NOW() + INTERVAL '25 hours';
```

### Paso 3.2: Crear workflow `Chatbot_Metricas_Nocturnas`

1. n8n → New Workflow → nombrar `Chatbot_Metricas_Nocturnas`
2. Cron: `58 23 * * *` (11:58 PM diario)
3. Agregar query: `SELECT calcular_metricas_diarias($empresa_id, CURRENT_DATE - 1)`
4. Agregar nodo de reporte por WA y Gmail

---

## DÍA 4 — VALIDACIÓN COMPLETA Y MONITOREO (1 hora)

### Checklist pre-cierre

**Base de datos:**
- [ ] Todas las tablas creadas: `\dt` en psql
- [ ] Todos los triggers activos: ver sección de verificación en 03_triggers.sql
- [ ] Índices creados: `\di` en psql
- [ ] Config real cargada (sin valores "REEMPLAZAR_CON_...")
- [ ] Usuarios migrados desde historial
- [ ] Test de overlap: intentar crear dos citas en mismo horario → debe fallar

**n8n Workflows:**
- [ ] Workflow principal activo con idempotencia
- [ ] Config cargando desde Postgres (no Google Sheets)
- [ ] Citas sincronizándose en BD después de agendar
- [ ] Recordatorio 24h activo
- [ ] Métricas nocturnas activas

**Funcional:**
- [ ] Mensaje de texto → respuesta correcta
- [ ] Mensaje de audio → transcripción → respuesta
- [ ] Agendar cita → aparece en Google Calendar Y en tabla `citas`
- [ ] Cancelar cita → desaparece de Google Calendar Y estado='cancelada' en BD
- [ ] Mensaje duplicado → ignorado (key_id UNIQUE)
- [ ] Usuario baneado → no puede agendar (mensaje genérico)

**Monitoreo:**
```sql
-- Ver errores de las últimas 24h
SELECT * FROM v_errores_pendientes WHERE created_at > NOW() - INTERVAL '24 hours';

-- Ver métricas de hoy
SELECT * FROM metricas_diarias WHERE fecha = CURRENT_DATE;

-- Ver últimas citas agendadas
SELECT c.titulo, c.inicio, c.estado, u.numero_limpio
FROM citas c JOIN usuarios u ON c.usuario_id = u.id
ORDER BY c.created_at DESC LIMIT 10;
```

---

## PLAN DE ROLLBACK

### Si algo sale mal en Paso 1 (DDL)
```sql
-- El script usa BEGIN/COMMIT. Si hay error antes del COMMIT:
ROLLBACK;
-- Las tablas nuevas se eliminan automáticamente.
-- El sistema original (Google Sheets) sigue funcionando.
```

### Si algo sale mal en Paso 2 (Workflow n8n)
```
1. n8n → Workflow activo → Toggle OFF
2. n8n → Abrir workflow backup "Chatbot_Isaac_BACKUP_20260508"
3. Toggle ON en el backup
4. Sistema restaurado en < 2 minutos
```

### Limpieza de tablas si necesitas empezar de nuevo
```sql
-- DANGER: Solo si necesitas borrar todo y empezar de cero
-- NO ejecutar en producción con datos reales

DROP TABLE IF EXISTS metricas_diarias CASCADE;
DROP TABLE IF EXISTS error_log CASCADE;
DROP TABLE IF EXISTS audit_log CASCADE;
DROP TABLE IF EXISTS citas CASCADE;
DROP TABLE IF EXISTS mensajes CASCADE;
DROP TABLE IF EXISTS sesiones CASCADE;
DROP TABLE IF EXISTS usuarios CASCADE;
DROP TABLE IF EXISTS config_negocio CASCADE;
DROP TABLE IF EXISTS instancias_whatsapp CASCADE;
DROP TABLE IF EXISTS empresas CASCADE;
DROP TYPE IF EXISTS estado_lead_enum CASCADE;
DROP TYPE IF EXISTS estado_sesion_enum CASCADE;
DROP TYPE IF EXISTS estado_cita_enum CASCADE;
DROP TYPE IF EXISTS canal_cita_enum CASCADE;
DROP TYPE IF EXISTS direccion_mensaje_enum CASCADE;
DROP TYPE IF EXISTS tipo_mensaje_enum CASCADE;
```

---

## QUERIES DE DEBUG EN PRODUCCIÓN

```sql
-- Estado general del sistema (ejecutar en cualquier momento)
SELECT
    (SELECT COUNT(*) FROM usuarios WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001') AS usuarios_total,
    (SELECT COUNT(*) FROM citas WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001' AND estado NOT IN ('cancelada')) AS citas_activas,
    (SELECT COUNT(*) FROM mensajes WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001' AND created_at > NOW() - INTERVAL '24h') AS mensajes_hoy,
    (SELECT COUNT(*) FROM error_log WHERE resuelto = false) AS errores_pendientes,
    (SELECT COUNT(*) FROM citas WHERE recordatorio_enviado = false AND inicio BETWEEN NOW() AND NOW() + INTERVAL '25h') AS recordatorios_pendientes;

-- Conversaciones activas en este momento
SELECT u.numero_limpio, u.nombre, s.ultimo_mensaje_at,
       NOW() - s.ultimo_mensaje_at AS inactivo_hace
FROM sesiones s
JOIN usuarios u ON s.usuario_id = u.id
WHERE s.estado = 'activa'
ORDER BY s.ultimo_mensaje_at DESC;

-- Top errores de la última semana
SELECT error_code, COUNT(*) AS ocurrencias, MAX(created_at) AS ultimo
FROM error_log
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY error_code
ORDER BY ocurrencias DESC;
```

---

## ARCHIVOS GENERADOS

| Archivo | Descripción | Ejecutar cuando |
|---|---|---|
| `docs/sql/01_schema_ddl.sql` | DDL completo con tablas y datos semilla | Día 1, Paso 1.1 |
| `docs/sql/02_indexes.sql` | Índices estratégicos (CONCURRENTLY) | Día 1, Paso 1.5 |
| `docs/sql/03_triggers.sql` | 7 triggers para updated_at, overlap, audit | Día 1, Paso 1.2 |
| `docs/sql/04_functions.sql` | 9 funciones PL/pgSQL + 3 vistas | Día 1, Paso 1.2 |
| `docs/sql/05_migration.sql` | Script de migración de datos existentes | Día 1, Paso 1.4 |
| `docs/sql/06_test_fixtures.sql` | Fixtures + test suite automatizado | Solo staging |
| `docs/n8n/WORKFLOW_ARCHITECTURE.md` | Especificación de los 13 sub-módulos | Referencia al implementar |
| `docs/analysis/ANALISIS_SISTEMA.md` | Análisis crítico actual vs propuesto | Referencia |
| `docs/rollout/PLAN_ROLLOUT.md` | Este archivo | Ejecutar en orden |
