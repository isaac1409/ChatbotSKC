-- ═══════════════════════════════════════════════════════════════════════════
-- INSTALL PARTE 1/2 — Tablas + Triggers + Funciones
-- ChatbotSKC / ZURA Solutions
-- Pegar completo en Easypanel Console → bot-citas-db
-- ═══════════════════════════════════════════════════════════════════════════

SET timezone = 'America/Mexico_City';

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- ─── TABLAS ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS empresas (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre              VARCHAR(255) NOT NULL,
    whatsapp_numero     VARCHAR(30),
    google_calendar_id  VARCHAR(255),
    timezone            VARCHAR(50)  NOT NULL DEFAULT 'America/Mexico_City',
    activa              BOOLEAN      NOT NULL DEFAULT true,
    metadata            JSONB        NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS instancias_whatsapp (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id              UUID        NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    nombre                  VARCHAR(100) NOT NULL,
    evolution_instance_name VARCHAR(100) NOT NULL UNIQUE,
    webhook_path            VARCHAR(255),
    activa                  BOOLEAN     NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config_negocio (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id  UUID        NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campo       VARCHAR(100) NOT NULL,
    valor       TEXT        NOT NULL,
    descripcion VARCHAR(500),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT config_negocio_empresa_campo_unique UNIQUE (empresa_id, campo)
);

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_lead_enum') THEN
        CREATE TYPE estado_lead_enum AS ENUM ('nuevo', 'contactado', 'calificado', 'convertido', 'perdido');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS usuarios (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id          UUID            NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    numero_whatsapp     VARCHAR(30)     NOT NULL,
    numero_limpio       VARCHAR(30)     NOT NULL,
    nombre              VARCHAR(255),
    email               VARCHAR(255),
    empresa_nombre      VARCHAR(255),
    servicio_interes    TEXT,
    problema            TEXT,
    estado_lead         estado_lead_enum NOT NULL DEFAULT 'nuevo',
    intentos_fallidos   INT             NOT NULL DEFAULT 0,
    baneado             BOOLEAN         NOT NULL DEFAULT false,
    baneado_hasta       TIMESTAMPTZ,
    metadata            JSONB           NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT usuarios_empresa_numero_unique UNIQUE (empresa_id, numero_limpio)
);

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_sesion_enum') THEN
        CREATE TYPE estado_sesion_enum AS ENUM ('activa', 'completada', 'expirada', 'abandonada');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS sesiones (
    id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id          UUID                NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    empresa_id          UUID                NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    session_key         VARCHAR(255)        NOT NULL UNIQUE,
    estado              estado_sesion_enum  NOT NULL DEFAULT 'activa',
    ultimo_mensaje_at   TIMESTAMPTZ,
    contexto            JSONB               NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'direccion_mensaje_enum') THEN
        CREATE TYPE direccion_mensaje_enum AS ENUM ('entrada', 'salida');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'tipo_mensaje_enum') THEN
        CREATE TYPE tipo_mensaje_enum AS ENUM ('texto', 'imagen', 'audio', 'documento', 'sticker', 'sistema');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS mensajes (
    id                  UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    sesion_id           UUID                    REFERENCES sesiones(id) ON DELETE SET NULL,
    usuario_id          UUID                    REFERENCES usuarios(id) ON DELETE SET NULL,
    empresa_id          UUID                    NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    key_id              VARCHAR(255)            UNIQUE,
    direccion           direccion_mensaje_enum  NOT NULL,
    tipo                tipo_mensaje_enum       NOT NULL DEFAULT 'texto',
    contenido           TEXT,
    contenido_original  TEXT,
    tokens_entrada      INT,
    tokens_salida       INT,
    procesado           BOOLEAN                 NOT NULL DEFAULT false,
    metadata            JSONB                   NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ             NOT NULL DEFAULT NOW()
);

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'estado_cita_enum') THEN
        CREATE TYPE estado_cita_enum AS ENUM ('pendiente','confirmada','cancelada','completada','no_asistio');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'canal_cita_enum') THEN
        CREATE TYPE canal_cita_enum AS ENUM ('whatsapp', 'directo', 'web', 'admin');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS citas (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id              UUID            NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    usuario_id              UUID            NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    google_event_id         VARCHAR(255)    UNIQUE,
    google_calendar_id      VARCHAR(255),
    titulo                  VARCHAR(255),
    descripcion             TEXT,
    inicio                  TIMESTAMPTZ     NOT NULL,
    fin                     TIMESTAMPTZ     NOT NULL,
    timezone                VARCHAR(50)     NOT NULL DEFAULT 'America/Mexico_City',
    estado                  estado_cita_enum NOT NULL DEFAULT 'pendiente',
    canal_agendamiento      canal_cita_enum NOT NULL DEFAULT 'whatsapp',
    reagendada_desde        UUID            REFERENCES citas(id) ON DELETE SET NULL,
    motivo_cancelacion      TEXT,
    confirmada_por_usuario  BOOLEAN         NOT NULL DEFAULT false,
    confirmada_at           TIMESTAMPTZ,
    recordatorio_enviado    BOOLEAN         NOT NULL DEFAULT false,
    recordatorio_at         TIMESTAMPTZ,
    version                 INT             NOT NULL DEFAULT 1,
    metadata                JSONB           NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT cita_inicio_antes_fin CHECK (inicio < fin),
    CONSTRAINT cita_duracion_razonable CHECK (fin - inicio <= INTERVAL '4 hours')
);

CREATE TABLE IF NOT EXISTS audit_log (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tabla_nombre        VARCHAR(100) NOT NULL,
    registro_id         UUID,
    operacion           VARCHAR(10)  NOT NULL CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    datos_anteriores    JSONB,
    datos_nuevos        JSONB,
    usuario_sistema     VARCHAR(100),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS error_log (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id      UUID        REFERENCES empresas(id) ON DELETE SET NULL,
    workflow_name   VARCHAR(100),
    node_name       VARCHAR(100),
    error_code      VARCHAR(50),
    error_message   TEXT,
    contexto        JSONB       NOT NULL DEFAULT '{}',
    resuelto        BOOLEAN     NOT NULL DEFAULT false,
    resuelto_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS metricas_diarias (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id                  UUID        NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    fecha                       DATE        NOT NULL,
    total_mensajes_entrada      INT         NOT NULL DEFAULT 0,
    total_mensajes_salida       INT         NOT NULL DEFAULT 0,
    usuarios_nuevos             INT         NOT NULL DEFAULT 0,
    usuarios_activos            INT         NOT NULL DEFAULT 0,
    citas_agendadas             INT         NOT NULL DEFAULT 0,
    citas_canceladas            INT         NOT NULL DEFAULT 0,
    citas_completadas           INT         NOT NULL DEFAULT 0,
    citas_no_asistio            INT         NOT NULL DEFAULT 0,
    leads_nuevos                INT         NOT NULL DEFAULT 0,
    leads_convertidos           INT         NOT NULL DEFAULT 0,
    tasa_conversion             DECIMAL(5,2),
    tokens_entrada_total        BIGINT      NOT NULL DEFAULT 0,
    tokens_salida_total         BIGINT      NOT NULL DEFAULT 0,
    tiempo_respuesta_promedio_ms INT,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT metricas_empresa_fecha_unique UNIQUE (empresa_id, fecha)
);

-- ─── DATOS SEMILLA ────────────────────────────────────────────────────────

INSERT INTO empresas (id, nombre, whatsapp_numero, google_calendar_id, timezone)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'ZURA Solutions',
    '5214921076419',
    'contacto.skcia@gmail.com',
    'America/Mexico_City'
) ON CONFLICT DO NOTHING;

INSERT INTO instancias_whatsapp (empresa_id, nombre, evolution_instance_name)
VALUES (
    'a0000000-0000-0000-0000-000000000001',
    'Instancia Principal',
    'Isaac'
) ON CONFLICT (evolution_instance_name) DO NOTHING;

INSERT INTO config_negocio (empresa_id, campo, valor) VALUES
    ('a0000000-0000-0000-0000-000000000001', 'nombre_empresa',   'ZURA Solutions'),
    ('a0000000-0000-0000-0000-000000000001', 'nombre_agente',    'Nova'),
    ('a0000000-0000-0000-0000-000000000001', 'horario_inicio',   '10:00 AM'),
    ('a0000000-0000-0000-0000-000000000001', 'horario_fin',      '5:00 PM'),
    ('a0000000-0000-0000-0000-000000000001', 'duracion_reunion', '30'),
    ('a0000000-0000-0000-0000-000000000001', 'modo_prueba',      'true'),
    ('a0000000-0000-0000-0000-000000000001', 'numero_admin',     'REEMPLAZAR'),
    ('a0000000-0000-0000-0000-000000000001', 'correo_admin',     'REEMPLAZAR'),
    ('a0000000-0000-0000-0000-000000000001', 'grupo_whatsapp',   'REEMPLAZAR')
ON CONFLICT (empresa_id, campo) DO NOTHING;

-- ─── TRIGGERS ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DO $$
DECLARE v_table TEXT;
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

CREATE OR REPLACE FUNCTION fn_validar_overlap_citas()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_conflicto RECORD;
BEGIN
    IF NEW.estado = 'cancelada' THEN RETURN NEW; END IF;
    SELECT id, titulo, inicio, fin INTO v_conflicto
    FROM citas
    WHERE empresa_id = NEW.empresa_id
      AND estado NOT IN ('cancelada')
      AND id IS DISTINCT FROM NEW.id
      AND tstzrange(inicio, fin, '[)') && tstzrange(NEW.inicio, NEW.fin, '[)')
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERLAP_CITAS: El slot % - % ya está ocupado por "%" (id: %)',
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

CREATE OR REPLACE FUNCTION fn_audit_citas()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (tabla_nombre, registro_id, operacion, datos_anteriores, datos_nuevos, usuario_sistema)
    VALUES (
        'citas', COALESCE(NEW.id, OLD.id), TG_OP,
        CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
        CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END,
        current_setting('app.usuario_sistema', true)
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_citas ON citas;
CREATE TRIGGER trg_audit_citas
    AFTER INSERT OR UPDATE OR DELETE ON citas
    FOR EACH ROW EXECUTE FUNCTION fn_audit_citas();

CREATE OR REPLACE FUNCTION fn_audit_usuarios()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (
        OLD.estado_lead IS DISTINCT FROM NEW.estado_lead OR
        OLD.baneado IS DISTINCT FROM NEW.baneado OR
        OLD.nombre IS DISTINCT FROM NEW.nombre OR
        OLD.email IS DISTINCT FROM NEW.email
    ) THEN
        INSERT INTO audit_log (tabla_nombre, registro_id, operacion, datos_anteriores, datos_nuevos, usuario_sistema)
        VALUES ('usuarios', NEW.id, TG_OP,
            jsonb_build_object('estado_lead', OLD.estado_lead, 'baneado', OLD.baneado, 'nombre', OLD.nombre),
            jsonb_build_object('estado_lead', NEW.estado_lead, 'baneado', NEW.baneado, 'nombre', NEW.nombre),
            current_setting('app.usuario_sistema', true));
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

CREATE OR REPLACE FUNCTION fn_sync_estado_lead_con_cita()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_citas_activas INT;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.estado IN ('pendiente', 'confirmada') THEN
        UPDATE usuarios SET estado_lead = 'convertido'
        WHERE id = NEW.usuario_id AND estado_lead NOT IN ('convertido');
    ELSIF TG_OP = 'UPDATE' AND NEW.estado = 'cancelada' AND OLD.estado != 'cancelada' THEN
        SELECT COUNT(*) INTO v_citas_activas FROM citas
        WHERE usuario_id = NEW.usuario_id
          AND estado NOT IN ('cancelada', 'completada', 'no_asistio')
          AND id != NEW.id;
        IF v_citas_activas = 0 THEN
            UPDATE usuarios SET estado_lead = 'calificado'
            WHERE id = NEW.usuario_id AND estado_lead = 'convertido';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_estado_lead ON citas;
CREATE TRIGGER trg_sync_estado_lead
    AFTER INSERT OR UPDATE OF estado ON citas
    FOR EACH ROW EXECUTE FUNCTION fn_sync_estado_lead_con_cita();

CREATE OR REPLACE FUNCTION fn_autobaneo_por_intentos()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.intentos_fallidos >= 3 AND OLD.intentos_fallidos < 3 THEN
        NEW.baneado = true;
        NEW.baneado_hasta = NOW() + INTERVAL '24 hours';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_autobaneo ON usuarios;
CREATE TRIGGER trg_autobaneo
    BEFORE UPDATE OF intentos_fallidos ON usuarios
    FOR EACH ROW EXECUTE FUNCTION fn_autobaneo_por_intentos();

CREATE OR REPLACE FUNCTION fn_config_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_config_updated_at ON config_negocio;
CREATE TRIGGER trg_config_updated_at
    BEFORE UPDATE ON config_negocio
    FOR EACH ROW EXECUTE FUNCTION fn_config_updated_at();

-- ─── FUNCIONES ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION upsert_usuario(
    p_empresa_id        UUID,
    p_numero_whatsapp   VARCHAR(255),
    p_nombre            VARCHAR(255)    DEFAULT NULL,
    p_email             VARCHAR(255)    DEFAULT NULL,
    p_empresa_nombre    VARCHAR(255)    DEFAULT NULL,
    p_servicio          TEXT            DEFAULT NULL,
    p_problema          TEXT            DEFAULT NULL,
    p_metadata          JSONB           DEFAULT '{}'
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_numero_limpio VARCHAR(30);
    v_usuario       usuarios%ROWTYPE;
    v_es_nuevo      BOOLEAN := false;
BEGIN
    v_numero_limpio := regexp_replace(p_numero_whatsapp, '@[^@]+$', '');
    v_numero_limpio := regexp_replace(v_numero_limpio, '\s+', '');
    SELECT * INTO v_usuario FROM usuarios
    WHERE empresa_id = p_empresa_id AND numero_limpio = v_numero_limpio;
    IF NOT FOUND THEN
        v_es_nuevo := true;
        INSERT INTO usuarios (empresa_id, numero_whatsapp, numero_limpio, nombre, email, empresa_nombre, servicio_interes, problema, metadata)
        VALUES (p_empresa_id, p_numero_whatsapp, v_numero_limpio, p_nombre, p_email, p_empresa_nombre, p_servicio, p_problema, COALESCE(p_metadata, '{}'))
        RETURNING * INTO v_usuario;
    ELSE
        UPDATE usuarios SET
            nombre           = COALESCE(p_nombre,         nombre),
            email            = COALESCE(p_email,          email),
            empresa_nombre   = COALESCE(p_empresa_nombre, empresa_nombre),
            servicio_interes = COALESCE(p_servicio,       servicio_interes),
            problema         = COALESCE(p_problema,       problema),
            metadata         = metadata || COALESCE(p_metadata, '{}')
        WHERE id = v_usuario.id RETURNING * INTO v_usuario;
    END IF;
    RETURN jsonb_build_object(
        'id', v_usuario.id, 'numero_limpio', v_usuario.numero_limpio,
        'nombre', v_usuario.nombre, 'email', v_usuario.email,
        'estado_lead', v_usuario.estado_lead, 'baneado', v_usuario.baneado,
        'baneado_hasta', v_usuario.baneado_hasta, 'intentos_fallidos', v_usuario.intentos_fallidos,
        'es_nuevo', v_es_nuevo, 'created_at', v_usuario.created_at
    );
END;
$$;

CREATE OR REPLACE FUNCTION get_config_empresa(p_empresa_id UUID)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_config JSONB := '{}';
    v_row    config_negocio%ROWTYPE;
BEGIN
    FOR v_row IN SELECT * FROM config_negocio WHERE empresa_id = p_empresa_id LOOP
        v_config := v_config || jsonb_build_object(v_row.campo, v_row.valor);
    END LOOP;
    v_config := v_config || (
        SELECT jsonb_build_object('empresa_id', id, 'timezone', timezone, 'activa', activa)
        FROM empresas WHERE id = p_empresa_id
    );
    RETURN v_config;
END;
$$;

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
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_cita citas%ROWTYPE;
BEGIN
    PERFORM set_config('app.usuario_sistema', 'workflow_agendar_cita', true);
    INSERT INTO citas (empresa_id, usuario_id, google_event_id, google_calendar_id, titulo, descripcion, inicio, fin, estado, canal_agendamiento, metadata)
    VALUES (p_empresa_id, p_usuario_id, p_google_event_id, p_google_cal_id, p_titulo, p_descripcion, p_inicio, p_fin, 'pendiente', 'whatsapp', COALESCE(p_metadata, '{}'))
    ON CONFLICT (google_event_id) DO UPDATE SET updated_at = NOW()
    RETURNING * INTO v_cita;
    RETURN jsonb_build_object(
        'id', v_cita.id, 'google_event_id', v_cita.google_event_id,
        'titulo', v_cita.titulo, 'inicio', v_cita.inicio, 'fin', v_cita.fin,
        'estado', v_cita.estado, 'es_duplicado', (v_cita.created_at != v_cita.updated_at)
    );
END;
$$;

CREATE OR REPLACE FUNCTION cancelar_cita_bd(
    p_google_event_id   VARCHAR(255),
    p_motivo            TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_cita citas%ROWTYPE;
BEGIN
    PERFORM set_config('app.usuario_sistema', 'workflow_cancelar_cita', true);
    UPDATE citas SET estado = 'cancelada', motivo_cancelacion = p_motivo
    WHERE google_event_id = p_google_event_id AND estado NOT IN ('cancelada', 'completada')
    RETURNING * INTO v_cita;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('exito', false, 'razon', 'cita_no_encontrada_o_ya_cancelada', 'google_event_id', p_google_event_id);
    END IF;
    RETURN jsonb_build_object('exito', true, 'id', v_cita.id, 'google_event_id', v_cita.google_event_id, 'titulo', v_cita.titulo, 'inicio', v_cita.inicio, 'usuario_id', v_cita.usuario_id);
END;
$$;

CREATE OR REPLACE FUNCTION obtener_citas_proximas_usuario(
    p_usuario_id UUID,
    p_dias INT DEFAULT 14
) RETURNS TABLE(cita_id UUID, google_event_id VARCHAR(255), titulo VARCHAR(255), inicio TIMESTAMPTZ, fin TIMESTAMPTZ, estado estado_cita_enum, dias_restantes INT)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.google_event_id, c.titulo, c.inicio, c.fin, c.estado,
           EXTRACT(DAY FROM c.inicio - NOW())::INT
    FROM citas c
    WHERE c.usuario_id = p_usuario_id
      AND c.estado NOT IN ('cancelada', 'completada', 'no_asistio')
      AND c.inicio BETWEEN NOW() AND NOW() + (p_dias || ' days')::INTERVAL
    ORDER BY c.inicio ASC;
END;
$$;

-- ─── VISTAS ───────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW v_proximas_citas AS
SELECT c.id, c.google_event_id, c.titulo,
       c.inicio AT TIME ZONE e.timezone AS inicio_local,
       c.fin    AT TIME ZONE e.timezone AS fin_local,
       c.estado, c.confirmada_por_usuario, c.recordatorio_enviado,
       u.numero_limpio AS usuario_numero, u.nombre AS usuario_nombre,
       u.email AS usuario_email, e.nombre AS empresa_nombre_skc, e.timezone
FROM citas c
JOIN usuarios u ON c.usuario_id = u.id
JOIN empresas e ON c.empresa_id = e.id
WHERE c.estado NOT IN ('cancelada', 'completada', 'no_asistio')
  AND c.inicio > NOW()
ORDER BY c.inicio ASC;

-- ─── VERIFICACIÓN FINAL ───────────────────────────────────────────────────

SELECT 'TABLAS CREADAS:' AS estado, COUNT(*) AS total
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

SELECT 'CONFIG CARGADA:' AS estado, COUNT(*) AS total FROM config_negocio;
