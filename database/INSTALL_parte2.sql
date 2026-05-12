-- ═══════════════════════════════════════════════════════════════════════════
-- INSTALL PARTE 2/2 — Índices
-- Ejecutar DESPUÉS de INSTALL_parte1.sql
-- IMPORTANTE: NO envolver en BEGIN/COMMIT (CONCURRENTLY lo requiere)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_key_id
    ON mensajes (key_id) WHERE key_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_usuario_fecha
    ON mensajes (usuario_id, created_at DESC) WHERE direccion = 'entrada';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_sin_procesar
    ON mensajes (created_at) WHERE procesado = false;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_mensajes_empresa_fecha
    ON mensajes (empresa_id, created_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_estado_lead
    ON usuarios (empresa_id, estado_lead, created_at DESC) WHERE baneado = false;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usuarios_baneados_activos
    ON usuarios (baneado_hasta) WHERE baneado = true AND baneado_hasta IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_overlap_empresa
    ON citas USING GIST (empresa_id, tstzrange(inicio, fin, '[)'))
    WHERE estado NOT IN ('cancelada');

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_usuario_activas
    ON citas (usuario_id, inicio)
    WHERE estado NOT IN ('cancelada', 'completada', 'no_asistio');

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_recordatorio_pendiente
    ON citas (inicio) WHERE recordatorio_enviado = false AND estado NOT IN ('cancelada');

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_citas_empresa_estado_inicio
    ON citas (empresa_id, estado, inicio DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_sesiones_empresa_activas
    ON sesiones (empresa_id, ultimo_mensaje_at DESC) WHERE estado = 'activa';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_tabla_registro
    ON audit_log (tabla_nombre, registro_id, created_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_errors_no_resueltos
    ON error_log (empresa_id, created_at DESC) WHERE resuelto = false;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_metricas_empresa_fecha
    ON metricas_diarias (empresa_id, fecha DESC);

-- ─── VERIFICACIÓN ─────────────────────────────────────────────────────────

SELECT 'ÍNDICES CREADOS:' AS estado, COUNT(*) AS total
FROM pg_indexes WHERE schemaname = 'public';
