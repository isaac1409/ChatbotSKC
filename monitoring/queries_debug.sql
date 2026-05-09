-- ═══════════════════════════════════════════════════════════════════════════
-- QUERIES DE MONITOREO Y DEBUG — ChatbotSKC
-- Ejecutar en psql o desde n8n para diagnóstico en producción.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- ESTADO GENERAL DEL SISTEMA
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    (SELECT COUNT(*) FROM usuarios
     WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1))     AS usuarios_total,
    (SELECT COUNT(*) FROM citas
     WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1)
       AND estado NOT IN ('cancelada'))                                                                                   AS citas_activas,
    (SELECT COUNT(*) FROM mensajes
     WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1)
       AND created_at > NOW() - INTERVAL '24h')                                                                          AS mensajes_hoy,
    (SELECT COUNT(*) FROM error_log
     WHERE resuelto = false)                                                                                              AS errores_pendientes,
    (SELECT COUNT(*) FROM citas
     WHERE recordatorio_enviado = false
       AND estado IN ('pendiente','confirmada')
       AND inicio BETWEEN NOW() AND NOW() + INTERVAL '25h')                                                              AS recordatorios_pendientes;


-- ─────────────────────────────────────────────────────────────────────────
-- CONVERSACIONES ACTIVAS AHORA
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    u.numero_limpio,
    u.nombre,
    u.estado_lead,
    s.ultimo_mensaje_at,
    NOW() - s.ultimo_mensaje_at AS inactivo_hace
FROM sesiones s
JOIN usuarios u ON s.usuario_id = u.id
WHERE s.estado = 'activa'
ORDER BY s.ultimo_mensaje_at DESC;


-- ─────────────────────────────────────────────────────────────────────────
-- CITAS PRÓXIMAS (próximas 48h)
-- ─────────────────────────────────────────────────────────────────────────

SELECT * FROM v_proximas_citas
WHERE inicio < NOW() + INTERVAL '48 hours'
ORDER BY inicio ASC;


-- ─────────────────────────────────────────────────────────────────────────
-- ERRORES NO RESUELTOS
-- ─────────────────────────────────────────────────────────────────────────

SELECT * FROM v_errores_pendientes
ORDER BY created_at DESC
LIMIT 50;


-- ─────────────────────────────────────────────────────────────────────────
-- TOP ERRORES DE LA ÚLTIMA SEMANA
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    error_code,
    origen,
    COUNT(*)         AS ocurrencias,
    MAX(created_at)  AS ultimo
FROM error_log
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY error_code, origen
ORDER BY ocurrencias DESC;


-- ─────────────────────────────────────────────────────────────────────────
-- MÉTRICAS DE LOS ÚLTIMOS 7 DÍAS
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    fecha,
    total_mensajes,
    usuarios_nuevos,
    citas_agendadas,
    citas_canceladas,
    citas_completadas,
    ROUND(tasa_conversion * 100, 1) AS tasa_conversion_pct,
    ROUND(tiempo_respuesta_avg_seg, 1) AS tiempo_resp_seg
FROM metricas_diarias
WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1)
  AND fecha >= CURRENT_DATE - 7
ORDER BY fecha DESC;


-- ─────────────────────────────────────────────────────────────────────────
-- MENSAJES DUPLICADOS (idempotencia check)
-- ─────────────────────────────────────────────────────────────────────────

SELECT key_id, COUNT(*) AS repeticiones
FROM mensajes
GROUP BY key_id
HAVING COUNT(*) > 1;
-- Debe retornar 0 filas. Si hay filas: la constraint UNIQUE falló.


-- ─────────────────────────────────────────────────────────────────────────
-- USUARIOS BANEADOS ACTIVOS
-- ─────────────────────────────────────────────────────────────────────────

SELECT numero_limpio, nombre, intentos_fallidos, baneado_hasta
FROM usuarios
WHERE baneado = true
  AND (baneado_hasta IS NULL OR baneado_hasta > NOW())
ORDER BY baneado_hasta DESC NULLS LAST;


-- ─────────────────────────────────────────────────────────────────────────
-- OVERLAP CHECK (no debe haber citas activas solapadas)
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    a.id AS cita_a,
    b.id AS cita_b,
    a.inicio AS inicio_a,
    a.fin    AS fin_a,
    b.inicio AS inicio_b,
    b.fin    AS fin_b
FROM citas a
JOIN citas b ON a.id < b.id
           AND a.empresa_id = b.empresa_id
           AND tstzrange(a.inicio, a.fin, '[)') && tstzrange(b.inicio, b.fin, '[)')
WHERE a.estado NOT IN ('cancelada')
  AND b.estado NOT IN ('cancelada');
-- Debe retornar 0 filas si los triggers de overlap funcionan correctamente.


-- ─────────────────────────────────────────────────────────────────────────
-- CONFIG ACTUAL (verificar que no hay placeholders)
-- ─────────────────────────────────────────────────────────────────────────

SELECT campo, valor
FROM config_negocio
WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1)
ORDER BY campo;
-- Buscar valores que contengan 'REEMPLAZAR_CON_' — ninguno debe existir en producción.


-- ─────────────────────────────────────────────────────────────────────────
-- ÚLTIMAS 20 CITAS AGENDADAS
-- ─────────────────────────────────────────────────────────────────────────

SELECT
    c.titulo,
    c.inicio AT TIME ZONE 'America/Mexico_City' AS inicio_mx,
    c.estado,
    c.recordatorio_enviado,
    u.numero_limpio,
    u.nombre
FROM citas c
JOIN usuarios u ON c.usuario_id = u.id
ORDER BY c.created_at DESC
LIMIT 20;
