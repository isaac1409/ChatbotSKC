-- ═══════════════════════════════════════════════════════════════════════════
-- DDL COMPLETO — ChatbotSKC / ZURA Solutions
-- PostgreSQL 14+  |  Timezone: America/Mexico_City
-- Generado: 2026-05-07
-- ═══════════════════════════════════════════════════════════════════════════
-- ORDEN DE EJECUCIÓN: Este archivo primero, luego 02, 03, 04
-- REQUIERE: extensión uuid-ossp o pgcrypto (gen_random_uuid())
-- ═══════════════════════════════════════════════════════════════════════════

-- Configurar timezone de la sesión
SET timezone = 'America/Mexico_City';

-- Extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "pgcrypto";    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "btree_gist"; -- índices GiST para tstzrange (overlap)

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: empresas
-- Fuente de verdad para multi-tenancy. Una fila por cliente de SKC.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS empresas (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre              VARCHAR(255) NOT NULL,
    whatsapp_numero     VARCHAR(30),             -- número principal de la empresa
    google_calendar_id  VARCHAR(255),            -- calendar ID de Google
    timezone            VARCHAR(50)  NOT NULL DEFAULT 'America/Mexico_City',
    activa              BOOLEAN      NOT NULL DEFAULT true,
    metadata            JSONB        NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE empresas IS 'Clientes de SKC. Una fila = una empresa con chatbot.';
COMMENT ON COLUMN empresas.google_calendar_id IS 'Calendar ID para crear eventos. Ej: contacto.skcia@gmail.com';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: instancias_whatsapp
-- Una empresa puede tener múltiples instancias de Evolution API.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS instancias_whatsapp (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id              UUID        NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    nombre                  VARCHAR(100) NOT NULL,
    evolution_instance_name VARCHAR(100) NOT NULL UNIQUE, -- nombre en Evolution API
    webhook_path            VARCHAR(255),                 -- path del webhook en n8n
    activa                  BOOLEAN     NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE instancias_whatsapp IS 'Instancias de Evolution API. Una empresa puede tener varias (ej: ventas, soporte).';
COMMENT ON COLUMN instancias_whatsapp.evolution_instance_name IS 'Nombre exacto en Evolution API. Ej: Isaac, ZURA';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: config_negocio
-- Reemplaza Google Sheets. Una fila por campo de configuración.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS config_negocio (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id  UUID        NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
    campo       VARCHAR(100) NOT NULL,
    valor       TEXT        NOT NULL,
    descripcion VARCHAR(500),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT config_negocio_empresa_campo_unique UNIQUE (empresa_id, campo)
);

COMMENT ON TABLE config_negocio IS 'Config dinámica por empresa. Reemplaza Google Sheets. Cacheable en Redis 5min.';
COMMENT ON COLUMN config_negocio.campo IS 'Campos reservados: nombre_empresa, nombre_agente, horario_inicio, horario_fin, duracion_reunion, numero_admin, correo_admin, grupo_whatsapp, modo_prueba';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: usuarios
-- Perfil persistente de cada contacto de WhatsApp.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TYPE estado_lead_enum AS ENUM ('nuevo', 'contactado', 'calificado', 'convertido', 'perdido');

CREATE TABLE IF NOT EXISTS usuarios (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id          UUID            NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    numero_whatsapp     VARCHAR(30)     NOT NULL,  -- formato: 5214921076419@s.whatsapp.net o solo número
    numero_limpio       VARCHAR(30)     NOT NULL,  -- número sin @s.whatsapp.net ni country prefix junk
    nombre              VARCHAR(255),
    email               VARCHAR(255),
    empresa_nombre      VARCHAR(255),              -- empresa DEL CLIENTE (no de SKC)
    servicio_interes    TEXT,
    problema            TEXT,
    estado_lead         estado_lead_enum NOT NULL DEFAULT 'nuevo',
    intentos_fallidos   INT             NOT NULL DEFAULT 0,
    baneado             BOOLEAN         NOT NULL DEFAULT false,
    baneado_hasta       TIMESTAMPTZ,               -- NULL = ban permanente
    metadata            JSONB           NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT usuarios_empresa_numero_unique UNIQUE (empresa_id, numero_limpio)
);

COMMENT ON TABLE usuarios IS 'Perfil persistente de cada contacto. Survives context window resets.';
COMMENT ON COLUMN usuarios.numero_limpio IS 'Solo dígitos del número, sin @s.whatsapp.net. Ej: 5214921076419';
COMMENT ON COLUMN usuarios.baneado_hasta IS 'Si es NULL y baneado=true → ban permanente. Si es timestamp futuro → ban temporal.';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: sesiones
-- Estado de conversación activa. Una sesión activa por usuario.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TYPE estado_sesion_enum AS ENUM ('activa', 'completada', 'expirada', 'abandonada');

CREATE TABLE IF NOT EXISTS sesiones (
    id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id          UUID                NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    empresa_id          UUID                NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    session_key         VARCHAR(255)        NOT NULL UNIQUE, -- = numero_limpio (n8n chat memory key)
    estado              estado_sesion_enum  NOT NULL DEFAULT 'activa',
    ultimo_mensaje_at   TIMESTAMPTZ,
    contexto            JSONB               NOT NULL DEFAULT '{}', -- eventId en proceso, flujo activo, etc.
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE sesiones IS 'Estado de conversación. contexto JSONB guarda state machine: evento en proceso, flujo activo, etc.';
COMMENT ON COLUMN sesiones.session_key IS 'Debe coincidir con sessionKey del nodo Postgres Chat Memory en n8n.';
COMMENT ON COLUMN sesiones.contexto IS 'Ejemplo: {"flujo_activo":"agendar","event_id_pending":"abc123","slot_candidato":"2026-05-10T10:00:00-06:00"}';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: mensajes
-- Log completo de conversaciones. key_id garantiza idempotencia.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TYPE direccion_mensaje_enum AS ENUM ('entrada', 'salida');
CREATE TYPE tipo_mensaje_enum AS ENUM ('texto', 'imagen', 'audio', 'documento', 'sticker', 'sistema');

CREATE TABLE IF NOT EXISTS mensajes (
    id                  UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    sesion_id           UUID                    REFERENCES sesiones(id) ON DELETE SET NULL,
    usuario_id          UUID                    REFERENCES usuarios(id) ON DELETE SET NULL,
    empresa_id          UUID                    NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    key_id              VARCHAR(255)            UNIQUE,     -- WhatsApp message ID (idempotencia)
    direccion           direccion_mensaje_enum  NOT NULL,
    tipo                tipo_mensaje_enum       NOT NULL DEFAULT 'texto',
    contenido           TEXT,                               -- texto procesado / transcripción
    contenido_original  TEXT,                               -- raw antes de normalización
    tokens_entrada      INT,                                -- tokens consumidos (si aplica)
    tokens_salida       INT,
    procesado           BOOLEAN                 NOT NULL DEFAULT false,
    metadata            JSONB                   NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ             NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE mensajes IS 'Log de todos los mensajes. key_id (WhatsApp msg ID) garantiza idempotencia.';
COMMENT ON COLUMN mensajes.key_id IS 'body.data.key.id de Evolution API. NULL = mensaje generado internamente.';
COMMENT ON COLUMN mensajes.contenido IS 'Para audio: transcripción. Para imagen: descripción. Para texto: texto original.';

-- Particionado por mes para escalar a millones de mensajes
-- NOTA: Activar cuando mensajes > 500K. Por ahora tabla normal.
-- CREATE TABLE mensajes PARTITION BY RANGE (created_at);
-- CREATE TABLE mensajes_2026_05 PARTITION OF mensajes FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: citas
-- Copia sincronizada de Google Calendar. google_event_id = idempotencia.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TYPE estado_cita_enum AS ENUM (
    'pendiente',        -- agendada, sin confirmar
    'confirmada',       -- usuario confirmó recordatorio 24h
    'cancelada',        -- cancelada (por usuario o admin)
    'completada',       -- reunión ocurrió
    'no_asistio'        -- usuario no se presentó
);

CREATE TYPE canal_cita_enum AS ENUM ('whatsapp', 'directo', 'web', 'admin');

CREATE TABLE IF NOT EXISTS citas (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id              UUID            NOT NULL REFERENCES empresas(id) ON DELETE RESTRICT,
    usuario_id              UUID            NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    google_event_id         VARCHAR(255)    UNIQUE,         -- eventId de Google Calendar (idempotencia)
    google_calendar_id      VARCHAR(255),                   -- qué calendar se usó
    titulo                  VARCHAR(255),                   -- summary del evento
    descripcion             TEXT,                           -- description del evento
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
    version                 INT             NOT NULL DEFAULT 1,  -- bloqueo optimista
    metadata                JSONB           NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT cita_inicio_antes_fin CHECK (inicio < fin),
    CONSTRAINT cita_duracion_razonable CHECK (fin - inicio <= INTERVAL '4 hours')
);

COMMENT ON TABLE citas IS 'Copia de Google Calendar en BD. google_event_id es la FK natural con GCal.';
COMMENT ON COLUMN citas.version IS 'Optimistic locking: UPDATE ... WHERE version = $1; si 0 rows → conflicto.';
COMMENT ON COLUMN citas.reagendada_desde IS 'Si esta cita reemplaza a otra, aquí va el ID de la anterior.';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: audit_log
-- Registro inmutable de todos los cambios en tablas críticas.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tabla_nombre        VARCHAR(100) NOT NULL,
    registro_id         UUID,
    operacion           VARCHAR(10)  NOT NULL CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    datos_anteriores    JSONB,
    datos_nuevos        JSONB,
    usuario_sistema     VARCHAR(100),                       -- nombre del workflow o proceso
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE audit_log IS 'Registro inmutable. NUNCA actualizar ni borrar filas de esta tabla.';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: error_log
-- Log de errores de workflows de n8n para debugging y alertas.
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS error_log (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id      UUID        REFERENCES empresas(id) ON DELETE SET NULL,
    workflow_name   VARCHAR(100),
    node_name       VARCHAR(100),
    error_code      VARCHAR(50),
    error_message   TEXT,
    contexto        JSONB       NOT NULL DEFAULT '{}',      -- datos del mensaje que causó el error
    resuelto        BOOLEAN     NOT NULL DEFAULT false,
    resuelto_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE error_log IS 'Errores de workflows n8n. Consultar para debugging. Marcar resuelto=true cuando se atiende.';

-- ─────────────────────────────────────────────────────────────────────────
-- TABLA: metricas_diarias
-- Agregados calculados cada medianoche. Una fila por empresa por día.
-- ─────────────────────────────────────────────────────────────────────────
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
    tasa_conversion             DECIMAL(5,2),                   -- leads_convertidos / leads_nuevos * 100
    tokens_entrada_total        BIGINT      NOT NULL DEFAULT 0,
    tokens_salida_total         BIGINT      NOT NULL DEFAULT 0,
    tiempo_respuesta_promedio_ms INT,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT metricas_empresa_fecha_unique UNIQUE (empresa_id, fecha)
);

COMMENT ON TABLE metricas_diarias IS 'KPIs diarios por empresa. Calculados por workflow nocturno. NO actualizar manualmente.';

-- ─────────────────────────────────────────────────────────────────────────
-- DATOS SEMILLA: empresa ZURA Solutions (producción actual)
-- ─────────────────────────────────────────────────────────────────────────
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

-- Config inicial (migrar desde Google Sheets)
INSERT INTO config_negocio (empresa_id, campo, valor) VALUES
    ('a0000000-0000-0000-0000-000000000001', 'nombre_empresa',   'ZURA Solutions'),
    ('a0000000-0000-0000-0000-000000000001', 'nombre_agente',    'Nova'),
    ('a0000000-0000-0000-0000-000000000001', 'horario_inicio',   '10:00 AM'),
    ('a0000000-0000-0000-0000-000000000001', 'horario_fin',      '5:00 PM'),
    ('a0000000-0000-0000-0000-000000000001', 'duracion_reunion', '30'),
    ('a0000000-0000-0000-0000-000000000001', 'modo_prueba',      'false'),
    ('a0000000-0000-0000-0000-000000000001', 'numero_admin',     'REEMPLAZAR_CON_NUMERO_REAL'),
    ('a0000000-0000-0000-0000-000000000001', 'correo_admin',     'REEMPLAZAR_CON_CORREO_REAL'),
    ('a0000000-0000-0000-0000-000000000001', 'grupo_whatsapp',   'REEMPLAZAR_CON_GRUPO_REAL')
ON CONFLICT (empresa_id, campo) DO NOTHING;
