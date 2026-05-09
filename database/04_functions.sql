-- ═══════════════════════════════════════════════════════════════════════════
-- FUNCIONES PL/pgSQL — ChatbotSKC
-- Ejecutar DESPUÉS de 01, 02, 03
-- ═══════════════════════════════════════════════════════════════════════════
-- Todas las funciones se llaman desde n8n con nodos Postgres (Execute Query).
-- Retornan JSONB para facilitar el consumo en n8n con $json.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- FN 1: upsert_usuario
-- Crea o actualiza el perfil de un usuario.
-- Llamar al inicio de cada mensaje para sincronizar datos del perfil.
-- n8n: SELECT upsert_usuario($1::uuid, $2, $3, $4, $5, $6, $7, $8)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_usuario(
    p_empresa_id        UUID,
    p_numero_whatsapp   VARCHAR(255),   -- puede venir con @s.whatsapp.net
    p_nombre            VARCHAR(255)    DEFAULT NULL,
    p_email             VARCHAR(255)    DEFAULT NULL,
    p_empresa_nombre    VARCHAR(255)    DEFAULT NULL,
    p_servicio          TEXT            DEFAULT NULL,
    p_problema          TEXT            DEFAULT NULL,
    p_metadata          JSONB           DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_numero_limpio VARCHAR(30);
    v_usuario       usuarios%ROWTYPE;
    v_es_nuevo      BOOLEAN := false;
BEGIN
    -- Normalizar número: quitar @s.whatsapp.net y espacios
    v_numero_limpio := regexp_replace(p_numero_whatsapp, '@[^@]+$', '');
    v_numero_limpio := regexp_replace(v_numero_limpio, '\s+', '');

    -- Intentar obtener usuario existente
    SELECT * INTO v_usuario
    FROM usuarios
    WHERE empresa_id = p_empresa_id AND numero_limpio = v_numero_limpio;

    IF NOT FOUND THEN
        -- Crear nuevo usuario
        v_es_nuevo := true;
        INSERT INTO usuarios (
            empresa_id, numero_whatsapp, numero_limpio,
            nombre, email, empresa_nombre, servicio_interes, problema, metadata
        ) VALUES (
            p_empresa_id, p_numero_whatsapp, v_numero_limpio,
            p_nombre, p_email, p_empresa_nombre, p_servicio, p_problema,
            COALESCE(p_metadata, '{}')
        )
        RETURNING * INTO v_usuario;
    ELSE
        -- Actualizar solo campos que vienen con valor (no sobreescribir con NULL)
        UPDATE usuarios SET
            nombre           = COALESCE(p_nombre,         nombre),
            email            = COALESCE(p_email,          email),
            empresa_nombre   = COALESCE(p_empresa_nombre, empresa_nombre),
            servicio_interes = COALESCE(p_servicio,       servicio_interes),
            problema         = COALESCE(p_problema,       problema),
            metadata         = metadata || COALESCE(p_metadata, '{}')
        WHERE id = v_usuario.id
        RETURNING * INTO v_usuario;
    END IF;

    RETURN jsonb_build_object(
        'id',               v_usuario.id,
        'numero_limpio',    v_usuario.numero_limpio,
        'nombre',           v_usuario.nombre,
        'email',            v_usuario.email,
        'empresa_nombre',   v_usuario.empresa_nombre,
        'estado_lead',      v_usuario.estado_lead,
        'baneado',          v_usuario.baneado,
        'baneado_hasta',    v_usuario.baneado_hasta,
        'intentos_fallidos',v_usuario.intentos_fallidos,
        'es_nuevo',         v_es_nuevo,
        'created_at',       v_usuario.created_at
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 2: validar_puede_agendar
-- Verifica si un usuario puede agendar una cita.
-- Retorna {puede: bool, razon: string, usuario: {...}}
-- n8n: SELECT validar_puede_agendar($1::uuid, $2::uuid)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION validar_puede_agendar(
    p_empresa_id    UUID,
    p_usuario_id    UUID
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_usuario       usuarios%ROWTYPE;
    v_citas_activas INT;
    v_empresa       empresas%ROWTYPE;
BEGIN
    -- Validar que la empresa exista y esté activa
    SELECT * INTO v_empresa FROM empresas WHERE id = p_empresa_id;
    IF NOT FOUND OR NOT v_empresa.activa THEN
        RETURN jsonb_build_object('puede', false, 'razon', 'empresa_inactiva');
    END IF;

    -- Obtener usuario
    SELECT * INTO v_usuario FROM usuarios WHERE id = p_usuario_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('puede', false, 'razon', 'usuario_no_encontrado');
    END IF;

    -- Verificar ban
    IF v_usuario.baneado THEN
        IF v_usuario.baneado_hasta IS NULL OR v_usuario.baneado_hasta > NOW() THEN
            RETURN jsonb_build_object(
                'puede', false,
                'razon', 'usuario_baneado',
                'baneado_hasta', v_usuario.baneado_hasta
            );
        ELSE
            -- Ban expiró, auto-desbanear
            UPDATE usuarios
            SET baneado = false, baneado_hasta = NULL, intentos_fallidos = 0
            WHERE id = v_usuario.id;
        END IF;
    END IF;

    -- Verificar intentos fallidos
    IF v_usuario.intentos_fallidos >= 3 THEN
        RETURN jsonb_build_object('puede', false, 'razon', 'demasiados_intentos_fallidos');
    END IF;

    -- Verificar si ya tiene cita pendiente (evitar doble agendamiento)
    SELECT COUNT(*) INTO v_citas_activas
    FROM citas
    WHERE usuario_id = v_usuario.id
      AND estado IN ('pendiente', 'confirmada')
      AND inicio > NOW();

    IF v_citas_activas >= 2 THEN
        RETURN jsonb_build_object(
            'puede', false,
            'razon', 'ya_tiene_cita_activa',
            'citas_activas', v_citas_activas
        );
    END IF;

    RETURN jsonb_build_object(
        'puede', true,
        'razon', 'ok',
        'usuario', jsonb_build_object(
            'id', v_usuario.id,
            'nombre', v_usuario.nombre,
            'estado_lead', v_usuario.estado_lead
        )
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 3: buscar_slots_disponibles
-- Genera lista de horarios libres en un rango de fechas.
-- Respeta horario de empresa y excluye fines de semana.
-- n8n: SELECT * FROM buscar_slots_disponibles($1::uuid, $2::timestamptz, $3::timestamptz, $4, $5, $6)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION buscar_slots_disponibles(
    p_empresa_id        UUID,
    p_desde             TIMESTAMPTZ,
    p_hasta             TIMESTAMPTZ,
    p_duracion_min      INT         DEFAULT 30,
    p_horario_inicio    TIME        DEFAULT '10:00:00',
    p_horario_fin       TIME        DEFAULT '17:00:00',
    p_max_slots         INT         DEFAULT 10
)
RETURNS TABLE(
    slot_inicio     TIMESTAMPTZ,
    slot_fin        TIMESTAMPTZ,
    disponible      BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_dia           DATE;
    v_slot          TIMESTAMPTZ;
    v_slot_fin      TIMESTAMPTZ;
    v_dia_fin_hora  TIMESTAMPTZ;
    v_count         INT := 0;
    v_tz            TEXT;
BEGIN
    -- Obtener timezone de la empresa
    SELECT timezone INTO v_tz FROM empresas WHERE id = p_empresa_id;
    v_tz := COALESCE(v_tz, 'America/Mexico_City');

    v_dia := (p_desde AT TIME ZONE v_tz)::DATE;

    WHILE v_dia <= (p_hasta AT TIME ZONE v_tz)::DATE AND v_count < p_max_slots LOOP
        -- Saltar sábado (6) y domingo (0)
        IF EXTRACT(DOW FROM v_dia) NOT IN (0, 6) THEN

            -- Inicio y fin del día laboral en la timezone de la empresa
            v_slot      := (v_dia::TEXT || ' ' || p_horario_inicio::TEXT)::TIMESTAMP
                           AT TIME ZONE v_tz;
            v_dia_fin_hora := (v_dia::TEXT || ' ' || p_horario_fin::TEXT)::TIMESTAMP
                               AT TIME ZONE v_tz;

            -- Ajustar inicio si p_desde está dentro del día
            IF v_slot < p_desde THEN
                -- Redondear p_desde al siguiente slot
                v_slot := p_desde + (
                    p_duracion_min - EXTRACT(MINUTE FROM p_desde)::INT % p_duracion_min
                ) * INTERVAL '1 minute';
                -- Limpiar segundos
                v_slot := date_trunc('minute', v_slot);
            END IF;

            WHILE v_slot < v_dia_fin_hora AND v_count < p_max_slots LOOP
                v_slot_fin := v_slot + (p_duracion_min || ' minutes')::INTERVAL;

                -- Verificar que el slot termina dentro del horario laboral
                IF v_slot_fin > v_dia_fin_hora THEN
                    EXIT;
                END IF;

                -- Verificar que el slot no solapa con citas existentes
                IF NOT EXISTS (
                    SELECT 1 FROM citas
                    WHERE empresa_id = p_empresa_id
                      AND estado NOT IN ('cancelada')
                      AND tstzrange(inicio, fin, '[)') && tstzrange(v_slot, v_slot_fin, '[)')
                ) THEN
                    slot_inicio := v_slot;
                    slot_fin    := v_slot_fin;
                    disponible  := true;
                    v_count     := v_count + 1;
                    RETURN NEXT;
                END IF;

                v_slot := v_slot + (p_duracion_min || ' minutes')::INTERVAL;
            END LOOP;
        END IF;

        v_dia := v_dia + 1;
    END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 4: registrar_cita
-- Crea la cita en PostgreSQL DESPUÉS de crearla en Google Calendar.
-- Usa google_event_id para idempotencia (ON CONFLICT DO UPDATE).
-- n8n: SELECT registrar_cita($1::uuid, $2::uuid, $3, $4, $5, $6::timestamptz, $7::timestamptz, $8, $9)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_cita(
    p_empresa_id        UUID,
    p_usuario_id        UUID,
    p_google_event_id   VARCHAR(255),
    p_google_cal_id     VARCHAR(255),
    p_titulo            VARCHAR(255),
    p_inicio            TIMESTAMPTZ,
    p_fin               TIMESTAMPTZ,
    p_descripcion       TEXT            DEFAULT NULL,
    p_metadata          JSONB           DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_cita  citas%ROWTYPE;
BEGIN
    -- SET para audit trail
    PERFORM set_config('app.usuario_sistema', 'workflow_agendar_cita', true);

    INSERT INTO citas (
        empresa_id, usuario_id, google_event_id, google_calendar_id,
        titulo, descripcion, inicio, fin, estado, canal_agendamiento, metadata
    ) VALUES (
        p_empresa_id, p_usuario_id, p_google_event_id, p_google_cal_id,
        p_titulo, p_descripcion, p_inicio, p_fin, 'pendiente', 'whatsapp',
        COALESCE(p_metadata, '{}')
    )
    ON CONFLICT (google_event_id) DO UPDATE SET
        -- Idempotencia: si se llama dos veces con el mismo event_id, no hacer nada
        -- pero sí retornar la cita existente
        updated_at = NOW()
    RETURNING * INTO v_cita;

    RETURN jsonb_build_object(
        'id',               v_cita.id,
        'google_event_id',  v_cita.google_event_id,
        'titulo',           v_cita.titulo,
        'inicio',           v_cita.inicio,
        'fin',              v_cita.fin,
        'estado',           v_cita.estado,
        'es_duplicado',     (v_cita.created_at != v_cita.updated_at)
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 5: cancelar_cita_bd
-- Marca la cita como cancelada en BD.
-- Retorna el google_event_id para que n8n pueda cancelar en Google Calendar.
-- n8n: SELECT cancelar_cita_bd($1, $2)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cancelar_cita_bd(
    p_google_event_id   VARCHAR(255),
    p_motivo            TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_cita  citas%ROWTYPE;
BEGIN
    PERFORM set_config('app.usuario_sistema', 'workflow_cancelar_cita', true);

    UPDATE citas SET
        estado              = 'cancelada',
        motivo_cancelacion  = p_motivo
    WHERE google_event_id = p_google_event_id
      AND estado NOT IN ('cancelada', 'completada')
    RETURNING * INTO v_cita;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'exito', false,
            'razon', 'cita_no_encontrada_o_ya_cancelada',
            'google_event_id', p_google_event_id
        );
    END IF;

    RETURN jsonb_build_object(
        'exito',            true,
        'id',               v_cita.id,
        'google_event_id',  v_cita.google_event_id,
        'titulo',           v_cita.titulo,
        'inicio',           v_cita.inicio,
        'usuario_id',       v_cita.usuario_id
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 6: reprogramar_cita
-- Cancela la cita vieja y registra la nueva con vínculo de historial.
-- n8n: SELECT reprogramar_cita($1, $2, $3::uuid, $4, $5::timestamptz, $6::timestamptz, $7)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION reprogramar_cita(
    p_google_event_id_viejo VARCHAR(255),
    p_google_event_id_nuevo VARCHAR(255),
    p_empresa_id            UUID,
    p_google_cal_id         VARCHAR(255),
    p_nuevo_inicio          TIMESTAMPTZ,
    p_nuevo_fin             TIMESTAMPTZ,
    p_titulo                VARCHAR(255)    DEFAULT NULL,
    p_descripcion           TEXT            DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_cita_vieja    citas%ROWTYPE;
    v_cita_nueva    citas%ROWTYPE;
BEGIN
    PERFORM set_config('app.usuario_sistema', 'workflow_reagendar_cita', true);

    -- Obtener y cancelar cita vieja
    UPDATE citas SET estado = 'cancelada', motivo_cancelacion = 'reagendada'
    WHERE google_event_id = p_google_event_id_viejo
    RETURNING * INTO v_cita_vieja;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('exito', false, 'razon', 'cita_vieja_no_encontrada');
    END IF;

    -- Crear cita nueva con referencia a la anterior
    INSERT INTO citas (
        empresa_id, usuario_id, google_event_id, google_calendar_id,
        titulo, descripcion, inicio, fin, estado, canal_agendamiento,
        reagendada_desde
    ) VALUES (
        p_empresa_id,
        v_cita_vieja.usuario_id,
        p_google_event_id_nuevo,
        p_google_cal_id,
        COALESCE(p_titulo, v_cita_vieja.titulo),
        COALESCE(p_descripcion, v_cita_vieja.descripcion),
        p_nuevo_inicio, p_nuevo_fin,
        'pendiente', 'whatsapp',
        v_cita_vieja.id
    )
    RETURNING * INTO v_cita_nueva;

    RETURN jsonb_build_object(
        'exito',                true,
        'cita_nueva_id',        v_cita_nueva.id,
        'cita_nueva_event_id',  v_cita_nueva.google_event_id,
        'cita_vieja_id',        v_cita_vieja.id,
        'nuevo_inicio',         v_cita_nueva.inicio,
        'nuevo_fin',            v_cita_nueva.fin
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 7: obtener_citas_proximas_usuario
-- Lista citas activas futuras de un usuario.
-- n8n: SELECT * FROM obtener_citas_proximas_usuario($1::uuid, $2)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION obtener_citas_proximas_usuario(
    p_usuario_id    UUID,
    p_dias          INT DEFAULT 14
)
RETURNS TABLE(
    cita_id         UUID,
    google_event_id VARCHAR(255),
    titulo          VARCHAR(255),
    inicio          TIMESTAMPTZ,
    fin             TIMESTAMPTZ,
    estado          estado_cita_enum,
    dias_restantes  INT
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        c.google_event_id,
        c.titulo,
        c.inicio,
        c.fin,
        c.estado,
        EXTRACT(DAY FROM c.inicio - NOW())::INT AS dias_restantes
    FROM citas c
    WHERE c.usuario_id = p_usuario_id
      AND c.estado NOT IN ('cancelada', 'completada', 'no_asistio')
      AND c.inicio BETWEEN NOW() AND NOW() + (p_dias || ' days')::INTERVAL
    ORDER BY c.inicio ASC;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 8: get_config_empresa
-- Retorna toda la config de una empresa como JSONB plano.
-- Diseñada para ser la fuente que reemplaza Google Sheets.
-- n8n: SELECT get_config_empresa($1::uuid)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_config_empresa(p_empresa_id UUID)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_config JSONB := '{}';
    v_row    config_negocio%ROWTYPE;
BEGIN
    FOR v_row IN
        SELECT * FROM config_negocio WHERE empresa_id = p_empresa_id
    LOOP
        v_config := v_config || jsonb_build_object(v_row.campo, v_row.valor);
    END LOOP;

    -- Agregar datos de la empresa
    v_config := v_config || (
        SELECT jsonb_build_object(
            'empresa_id',   id,
            'timezone',     timezone,
            'activa',       activa
        )
        FROM empresas WHERE id = p_empresa_id
    );

    RETURN v_config;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- FN 9: calcular_metricas_diarias
-- Llamar desde workflow nocturno. Upsert de métricas del día anterior.
-- n8n: SELECT calcular_metricas_diarias($1::uuid, $2::date)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION calcular_metricas_diarias(
    p_empresa_id    UUID,
    p_fecha         DATE DEFAULT CURRENT_DATE - 1
)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_inicio    TIMESTAMPTZ := p_fecha::TIMESTAMPTZ AT TIME ZONE 'America/Mexico_City';
    v_fin       TIMESTAMPTZ := (p_fecha + 1)::TIMESTAMPTZ AT TIME ZONE 'America/Mexico_City';
    v_result    JSONB;
BEGIN
    INSERT INTO metricas_diarias (
        empresa_id, fecha,
        total_mensajes_entrada,
        total_mensajes_salida,
        usuarios_nuevos,
        usuarios_activos,
        citas_agendadas,
        citas_canceladas,
        citas_completadas,
        leads_nuevos,
        leads_convertidos,
        tasa_conversion
    )
    SELECT
        p_empresa_id,
        p_fecha,
        COUNT(*) FILTER (WHERE m.direccion = 'entrada')      AS total_mensajes_entrada,
        COUNT(*) FILTER (WHERE m.direccion = 'salida')       AS total_mensajes_salida,
        (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(created_at) = p_fecha),
        COUNT(DISTINCT m.usuario_id),
        (SELECT COUNT(*) FROM citas WHERE empresa_id = p_empresa_id AND DATE(created_at) = p_fecha AND estado != 'cancelada'),
        (SELECT COUNT(*) FROM citas WHERE empresa_id = p_empresa_id AND DATE(updated_at) = p_fecha AND estado = 'cancelada'),
        (SELECT COUNT(*) FROM citas WHERE empresa_id = p_empresa_id AND DATE(inicio) = p_fecha AND estado = 'completada'),
        (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(created_at) = p_fecha),
        (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(updated_at) = p_fecha AND estado_lead = 'convertido'),
        CASE
            WHEN (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(created_at) = p_fecha) = 0 THEN 0
            ELSE ROUND(
                (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(updated_at) = p_fecha AND estado_lead = 'convertido')::DECIMAL
                / (SELECT COUNT(*) FROM usuarios WHERE empresa_id = p_empresa_id AND DATE(created_at) = p_fecha) * 100,
                2
            )
        END
    FROM mensajes m
    WHERE m.empresa_id = p_empresa_id
      AND m.created_at BETWEEN v_inicio AND v_fin
    ON CONFLICT (empresa_id, fecha) DO UPDATE SET
        total_mensajes_entrada  = EXCLUDED.total_mensajes_entrada,
        total_mensajes_salida   = EXCLUDED.total_mensajes_salida,
        usuarios_nuevos         = EXCLUDED.usuarios_nuevos,
        usuarios_activos        = EXCLUDED.usuarios_activos,
        citas_agendadas         = EXCLUDED.citas_agendadas,
        citas_canceladas        = EXCLUDED.citas_canceladas,
        citas_completadas       = EXCLUDED.citas_completadas,
        leads_nuevos            = EXCLUDED.leads_nuevos,
        leads_convertidos       = EXCLUDED.leads_convertidos,
        tasa_conversion         = EXCLUDED.tasa_conversion,
        updated_at              = NOW();

    SELECT to_jsonb(md) INTO v_result
    FROM metricas_diarias md
    WHERE empresa_id = p_empresa_id AND fecha = p_fecha;

    RETURN v_result;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- VISTAS ÚTILES
-- ─────────────────────────────────────────────────────────────────────────

-- Vista: próximas citas con datos completos
CREATE OR REPLACE VIEW v_proximas_citas AS
SELECT
    c.id,
    c.google_event_id,
    c.titulo,
    c.inicio AT TIME ZONE e.timezone AS inicio_local,
    c.fin    AT TIME ZONE e.timezone AS fin_local,
    c.estado,
    c.confirmada_por_usuario,
    c.recordatorio_enviado,
    u.numero_limpio         AS usuario_numero,
    u.nombre                AS usuario_nombre,
    u.email                 AS usuario_email,
    u.empresa_nombre,
    e.nombre                AS empresa_nombre_skc,
    e.timezone
FROM citas c
JOIN usuarios u ON c.usuario_id = u.id
JOIN empresas e ON c.empresa_id = e.id
WHERE c.estado NOT IN ('cancelada', 'completada', 'no_asistio')
  AND c.inicio > NOW()
ORDER BY c.inicio ASC;

COMMENT ON VIEW v_proximas_citas IS 'Citas futuras activas con datos de usuario y empresa. Usar para recordatorios.';

-- Vista: dashboard de leads
CREATE OR REPLACE VIEW v_dashboard_leads AS
SELECT
    e.nombre                AS empresa,
    u.estado_lead,
    COUNT(*)                AS total,
    COUNT(*) FILTER (WHERE u.created_at > NOW() - INTERVAL '7 days') AS nuevos_7d,
    COUNT(*) FILTER (WHERE u.created_at > NOW() - INTERVAL '30 days') AS nuevos_30d
FROM usuarios u
JOIN empresas e ON u.empresa_id = e.id
WHERE u.baneado = false
GROUP BY e.nombre, u.estado_lead
ORDER BY e.nombre, u.estado_lead;

-- Vista: errores recientes sin resolver
CREATE OR REPLACE VIEW v_errores_pendientes AS
SELECT
    el.id,
    e.nombre AS empresa,
    el.workflow_name,
    el.node_name,
    el.error_code,
    el.error_message,
    el.created_at,
    NOW() - el.created_at AS hace_cuanto
FROM error_log el
LEFT JOIN empresas e ON el.empresa_id = e.id
WHERE el.resuelto = false
ORDER BY el.created_at DESC;

-- ─────────────────────────────────────────────────────────────────────────
-- QUERIES DE AUDITORÍA / DEBUG
-- ─────────────────────────────────────────────────────────────────────────

/*
-- Historia completa de una cita:
SELECT
    to_char(created_at AT TIME ZONE 'America/Mexico_City', 'YYYY-MM-DD HH:MI:SS') AS cuando,
    operacion,
    usuario_sistema,
    datos_anteriores->>'estado' AS estado_antes,
    datos_nuevos->>'estado'     AS estado_despues
FROM audit_log
WHERE tabla_nombre = 'citas'
  AND registro_id = '<uuid-de-la-cita>'
ORDER BY created_at;

-- Usuarios con ban activo:
SELECT numero_limpio, nombre, baneado_hasta, intentos_fallidos
FROM usuarios
WHERE baneado = true AND (baneado_hasta IS NULL OR baneado_hasta > NOW());

-- Citas sin sincronizar con Google Calendar (null event_id):
SELECT * FROM citas WHERE google_event_id IS NULL AND estado != 'cancelada';

-- Tasa de conversión últimos 30 días:
SELECT
    empresa_id,
    SUM(leads_nuevos)     AS leads_total,
    SUM(leads_convertidos) AS convertidos,
    ROUND(AVG(tasa_conversion), 2) AS tasa_promedio
FROM metricas_diarias
WHERE fecha >= CURRENT_DATE - 30
GROUP BY empresa_id;
*/
