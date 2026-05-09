-- ═══════════════════════════════════════════════════════════════════════════
-- TRIGGERS — ChatbotSKC
-- Ejecutar DESPUÉS de 01_schema_ddl.sql y 02_indexes.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 1: updated_at automático
-- Se aplica a TODAS las tablas con columna updated_at.
-- WHY: Evita que n8n tenga que setear updated_at manualmente (se olvidaría).
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Aplicar a cada tabla con updated_at
DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'empresas', 'instancias_whatsapp', 'usuarios',
        'sesiones', 'citas', 'metricas_diarias'
    ]
    LOOP
        EXECUTE format('
            DROP TRIGGER IF EXISTS trg_set_updated_at ON %I;
            CREATE TRIGGER trg_set_updated_at
            BEFORE UPDATE ON %I
            FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
        ', v_table, v_table);
    END LOOP;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 2: Validar overlap de citas
-- WHY: Previene overbooking concurrente que Google Calendar permite.
-- CUÁNDO: BEFORE INSERT OR UPDATE en citas.
-- EXCEPCIÓN: si es la misma cita (UPDATE) o si el nuevo estado es 'cancelada'.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_validar_overlap_citas()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_conflicto RECORD;
BEGIN
    -- Si se está cancelando, no validar overlap
    IF NEW.estado = 'cancelada' THEN
        RETURN NEW;
    END IF;

    -- Buscar cualquier cita no cancelada que se superponga
    SELECT id, titulo, inicio, fin
    INTO v_conflicto
    FROM citas
    WHERE empresa_id = NEW.empresa_id
      AND estado NOT IN ('cancelada')
      AND id IS DISTINCT FROM NEW.id          -- excluir la misma cita en UPDATEs
      AND tstzrange(inicio, fin, '[)') && tstzrange(NEW.inicio, NEW.fin, '[)')
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'OVERLAP_CITAS: El slot % - % ya está ocupado por la cita "%" (id: %)',
            NEW.inicio, NEW.fin, v_conflicto.titulo, v_conflicto.id
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_overlap_citas ON citas;
CREATE TRIGGER trg_validar_overlap_citas
    BEFORE INSERT OR UPDATE OF inicio, fin, estado ON citas
    FOR EACH ROW EXECUTE FUNCTION fn_validar_overlap_citas();

COMMENT ON FUNCTION fn_validar_overlap_citas() IS
    'Previene overbooking. Lanza excepción SQLSTATE P0001 si hay conflicto. n8n debe capturar este error.';

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 3: Audit log automático en citas
-- WHY: Trazabilidad completa de cambios. Quién, qué, cuándo.
-- CUÁNDO: AFTER INSERT OR UPDATE OR DELETE en citas.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_audit_citas()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (
        tabla_nombre,
        registro_id,
        operacion,
        datos_anteriores,
        datos_nuevos,
        usuario_sistema
    ) VALUES (
        'citas',
        COALESCE(NEW.id, OLD.id),
        TG_OP,
        CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END,
        current_setting('app.usuario_sistema', true)  -- setear en n8n: SET LOCAL app.usuario_sistema = 'workflow_name'
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_citas ON citas;
CREATE TRIGGER trg_audit_citas
    AFTER INSERT OR UPDATE OR DELETE ON citas
    FOR EACH ROW EXECUTE FUNCTION fn_audit_citas();

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 4: Audit log en usuarios
-- WHY: Rastrear cambios de estado_lead y datos de perfil.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_audit_usuarios()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- Solo auditar si cambiaron campos relevantes
    IF TG_OP = 'UPDATE' AND (
        OLD.estado_lead    IS DISTINCT FROM NEW.estado_lead   OR
        OLD.baneado        IS DISTINCT FROM NEW.baneado       OR
        OLD.nombre         IS DISTINCT FROM NEW.nombre        OR
        OLD.email          IS DISTINCT FROM NEW.email         OR
        OLD.empresa_nombre IS DISTINCT FROM NEW.empresa_nombre
    ) THEN
        INSERT INTO audit_log (tabla_nombre, registro_id, operacion, datos_anteriores, datos_nuevos, usuario_sistema)
        VALUES (
            'usuarios', NEW.id, TG_OP,
            jsonb_build_object(
                'estado_lead', OLD.estado_lead, 'baneado', OLD.baneado,
                'nombre', OLD.nombre, 'email', OLD.email, 'empresa_nombre', OLD.empresa_nombre
            ),
            jsonb_build_object(
                'estado_lead', NEW.estado_lead, 'baneado', NEW.baneado,
                'nombre', NEW.nombre, 'email', NEW.email, 'empresa_nombre', NEW.empresa_nombre
            ),
            current_setting('app.usuario_sistema', true)
        );
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (tabla_nombre, registro_id, operacion, datos_anteriores, datos_nuevos, usuario_sistema)
        VALUES ('usuarios', NEW.id, 'INSERT', NULL, to_jsonb(NEW), current_setting('app.usuario_sistema', true));
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_usuarios ON usuarios;
CREATE TRIGGER trg_audit_usuarios
    AFTER INSERT OR UPDATE ON usuarios
    FOR EACH ROW EXECUTE FUNCTION fn_audit_usuarios();

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 5: Sincronizar estado_lead al agendar cita
-- WHY: Cuando se agenda una cita, el lead automáticamente es 'convertido'.
--      Cuando se cancela la única cita activa, puede volver a 'calificado'.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_sync_estado_lead_con_cita()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_citas_activas INT;
BEGIN
    -- Al insertar cita pendiente/confirmada → usuario = convertido
    IF TG_OP = 'INSERT' AND NEW.estado IN ('pendiente', 'confirmada') THEN
        UPDATE usuarios
        SET estado_lead = 'convertido'
        WHERE id = NEW.usuario_id
          AND estado_lead NOT IN ('convertido');

    -- Al cancelar → revisar si quedan citas activas
    ELSIF TG_OP = 'UPDATE' AND NEW.estado = 'cancelada' AND OLD.estado != 'cancelada' THEN
        SELECT COUNT(*) INTO v_citas_activas
        FROM citas
        WHERE usuario_id = NEW.usuario_id
          AND estado NOT IN ('cancelada', 'completada', 'no_asistio')
          AND id != NEW.id;

        IF v_citas_activas = 0 THEN
            UPDATE usuarios
            SET estado_lead = 'calificado'
            WHERE id = NEW.usuario_id
              AND estado_lead = 'convertido';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_estado_lead ON citas;
CREATE TRIGGER trg_sync_estado_lead
    AFTER INSERT OR UPDATE OF estado ON citas
    FOR EACH ROW EXECUTE FUNCTION fn_sync_estado_lead_con_cita();

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 6: Validar intentos fallidos y autobaneo temporal
-- WHY: Previene abuso. Si un usuario falla 3 veces, baneo de 24h automático.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_autobaneo_por_intentos()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- Si se incrementó intentos_fallidos y llega a 3
    IF NEW.intentos_fallidos >= 3 AND OLD.intentos_fallidos < 3 THEN
        NEW.baneado = true;
        NEW.baneado_hasta = NOW() + INTERVAL '24 hours';

        INSERT INTO audit_log (tabla_nombre, registro_id, operacion, datos_anteriores, datos_nuevos, usuario_sistema)
        VALUES (
            'usuarios', NEW.id, 'UPDATE',
            jsonb_build_object('baneado', false, 'intentos_fallidos', OLD.intentos_fallidos),
            jsonb_build_object('baneado', true, 'baneado_hasta', NEW.baneado_hasta),
            'trigger_autobaneo'
        );
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_autobaneo ON usuarios;
CREATE TRIGGER trg_autobaneo
    BEFORE UPDATE OF intentos_fallidos ON usuarios
    FOR EACH ROW EXECUTE FUNCTION fn_autobaneo_por_intentos();

-- ─────────────────────────────────────────────────────────────────────────
-- TRIGGER 7: config_negocio updated_at (separado porque no tiene trigger set)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_config_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_config_updated_at ON config_negocio;
CREATE TRIGGER trg_config_updated_at
    BEFORE UPDATE ON config_negocio
    FOR EACH ROW EXECUTE FUNCTION fn_config_updated_at();

-- ─────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN: Ver todos los triggers activos
-- ─────────────────────────────────────────────────────────────────────────
/*
SELECT
    trigger_name,
    event_object_table AS tabla,
    event_manipulation AS evento,
    action_timing AS timing,
    action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table, trigger_name;
*/
