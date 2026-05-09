-- ═══════════════════════════════════════════════════════════════════════════
-- ÍNDICES ESTRATÉGICOS — ChatbotSKC
-- Ejecutar DESPUÉS de 01_schema_ddl.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- JUSTIFICACIÓN POR ÍNDICE: cada índice resuelve una query de alta frecuencia.
-- CONCURRENTLY: los índices de producción se crean CONCURRENTLY para no bloquear.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: mensajes
-- Query más frecuente: "¿ya procesé este mensaje?" → deduplicación
-- ─────────────────────────────────────────────────────────────────────────

-- Idempotencia: lookup por key_id de WhatsApp (ya cubierto por UNIQUE, pero explícito)
-- Cardinalidad alta → B-tree es óptimo
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_key_id
    ON mensajes (key_id)
    WHERE key_id IS NOT NULL;

-- Historial de conversación de un usuario (paginado, orden desc)
-- Cubre: SELECT * FROM mensajes WHERE usuario_id = $1 ORDER BY created_at DESC LIMIT 50
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_usuario_fecha
    ON mensajes (usuario_id, created_at DESC)
    WHERE direccion = 'entrada';

-- Mensajes sin procesar (cola de trabajo)
-- Cubre: SELECT * FROM mensajes WHERE procesado = false ORDER BY created_at
-- Partial index: solo filas donde procesado=false (cardinalidad baja, ahorra espacio)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_sin_procesar
    ON mensajes (created_at)
    WHERE procesado = false;

-- Mensajes por empresa para reportes
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_empresa_fecha
    ON mensajes (empresa_id, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: usuarios
-- Queries frecuentes: buscar por número, filtrar leads activos
-- ─────────────────────────────────────────────────────────────────────────

-- Lookup principal: "¿existe este número en esta empresa?"
-- Ya cubierto por UNIQUE constraint, pero creamos explícitamente para CONCURRENTLY
-- (el índice UNIQUE se crea durante CREATE TABLE, bloqueando)
-- Este ya existe implícito; lo documentamos aquí para claridad.
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_empresa_numero
--     ON usuarios (empresa_id, numero_limpio);

-- Leads activos para campañas o reportes
-- Partial: solo leads no baneados (la mayoría)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_estado_lead
    ON usuarios (empresa_id, estado_lead, created_at DESC)
    WHERE baneado = false;

-- Usuarios baneados con ban temporal (para job de desbloqueo automático)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_baneados_activos
    ON usuarios (baneado_hasta)
    WHERE baneado = true AND baneado_hasta IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: citas
-- Queries críticas: overlap detection, buscar citas de usuario, recordatorios
-- ─────────────────────────────────────────────────────────────────────────

-- CRÍTICO: Detección de overlap para prevenir overbooking
-- GiST index sobre tstzrange → O(log n) para operadores &&, @>, <@
-- Requiere extensión btree_gist (ya activada en DDL)
-- Cubre: WHERE empresa_id = $1 AND tstzrange(inicio, fin, '[)') && tstzrange($2, $3, '[)')
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_overlap_empresa
    ON citas USING GIST (empresa_id, tstzrange(inicio, fin, '[)'))
    WHERE estado NOT IN ('cancelada');

-- Citas activas de un usuario (para listar próximas citas)
-- Cubre: WHERE usuario_id = $1 AND estado NOT IN ('cancelada') ORDER BY inicio
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_usuario_activas
    ON citas (usuario_id, inicio)
    WHERE estado NOT IN ('cancelada', 'completada', 'no_asistio');

-- Idempotencia por google_event_id
-- Ya cubierto por UNIQUE constraint (creado en DDL)
-- Documentamos aquí para referencia.

-- Recordatorios pendientes (job nocturno)
-- Cubre: WHERE inicio BETWEEN now() AND now()+24h AND recordatorio_enviado = false
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_recordatorio_pendiente
    ON citas (inicio)
    WHERE recordatorio_enviado = false AND estado NOT IN ('cancelada');

-- Citas por empresa para reportes y métricas
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_empresa_estado_inicio
    ON citas (empresa_id, estado, inicio DESC);

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: sesiones
-- Query principal: lookup por session_key (ya UNIQUE, documentado)
-- ─────────────────────────────────────────────────────────────────────────

-- Sesiones activas de una empresa (para limpieza / monitoreo)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_sesiones_empresa_activas
    ON sesiones (empresa_id, ultimo_mensaje_at DESC)
    WHERE estado = 'activa';

-- Sesiones expiradas para cleanup job
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_sesiones_expiradas
    ON sesiones (ultimo_mensaje_at)
    WHERE estado = 'activa' AND ultimo_mensaje_at < NOW() - INTERVAL '24 hours';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: audit_log
-- Query de debugging: "¿qué pasó con este registro?"
-- ─────────────────────────────────────────────────────────────────────────

-- Historial de cambios de un registro específico
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_tabla_registro
    ON audit_log (tabla_nombre, registro_id, created_at DESC);

-- Timeline de auditoría por empresa (requiere join, pero útil)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_fecha
    ON audit_log (created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: error_log
-- Query de monitoreo: errores recientes sin resolver
-- ─────────────────────────────────────────────────────────────────────────

-- Errores activos para alertas
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_errors_no_resueltos
    ON error_log (empresa_id, created_at DESC)
    WHERE resuelto = false;

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: config_negocio
-- Query: "dame toda la config de empresa X"
-- ─────────────────────────────────────────────────────────────────────────
-- Ya cubierto por UNIQUE(empresa_id, campo). No se necesitan índices adicionales.

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: metricas_diarias
-- Query: rangos de fecha para dashboard
-- ─────────────────────────────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_metricas_empresa_fecha
    ON metricas_diarias (empresa_id, fecha DESC);

-- ─────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN: Ver tamaños de índices (ejecutar después de cargar datos)
-- ─────────────────────────────────────────────────────────────────────────
/*
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
*/

-- ─────────────────────────────────────────────────────────────────────────
-- QUERY DE DEBUGGING DE PERFORMANCE (usar con EXPLAIN ANALYZE)
-- ─────────────────────────────────────────────────────────────────────────
/*
-- Test overlap query:
EXPLAIN ANALYZE
SELECT id, titulo, inicio, fin
FROM citas
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
  AND estado NOT IN ('cancelada')
  AND tstzrange(inicio, fin, '[)') && tstzrange(
    '2026-05-10 10:00:00-06:00'::TIMESTAMPTZ,
    '2026-05-10 10:30:00-06:00'::TIMESTAMPTZ,
    '[)'
  );
-- Esperado: Bitmap Index Scan on idx_citas_overlap_empresa
-- Costo esperado: < 5ms con índice GiST
*/
