-- ═══════════════════════════════════════════════════════════════════════════
-- MIGRATION SCRIPT — De sistema actual a sistema optimizado
-- ChatbotSKC / ZURA Solutions
-- ═══════════════════════════════════════════════════════════════════════════
-- PREREQUISITOS:
--   1. Backup completo de PostgreSQL ejecutado
--   2. n8n en modo mantenimiento (deshabilitar webhook temporalmente)
--   3. Ejecutar este script en una transacción
--   4. Tiempo estimado: 5-10 minutos
-- ═══════════════════════════════════════════════════════════════════════════
-- INSTRUCCIONES:
--   psql -U postgres -d <database> -f 05_migration.sql 2>&1 | tee migration.log
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 0: Verificaciones pre-migración
-- ─────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    -- Verificar que estamos en la BD correcta
    IF current_database() = 'postgres' THEN
        RAISE EXCEPTION 'ERROR: Estás en la BD "postgres". Conéctate a la BD de producción.';
    END IF;

    -- Verificar que las extensiones están disponibles
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        RAISE EXCEPTION 'ERROR: Extensión pgcrypto no disponible. Ejecutar: CREATE EXTENSION pgcrypto;';
    END IF;

    RAISE NOTICE 'PRE-CHECK: BD = %, OK', current_database();
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 1: Verificar tablas existentes de n8n (NO modificar)
-- ─────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    -- Las tablas de n8n que ya existen y NO se tocan:
    -- n8n_chat_histories, execution_entity, workflow_entity, etc.

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'n8n_chat_histories') THEN
        RAISE NOTICE 'PASO 1: Tabla n8n_chat_histories encontrada → se preserva intacta';
    ELSE
        RAISE NOTICE 'PASO 1: n8n_chat_histories no existe aún (n8n la crea al primer uso)';
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 2: Crear todas las tablas nuevas (idempotente por IF NOT EXISTS)
-- ─────────────────────────────────────────────────────────────────────────

-- Ejecutar DDL (ya tiene IF NOT EXISTS, es seguro re-ejecutar)
\i 01_schema_ddl.sql

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 3: Crear índices (CONCURRENTLY no funciona dentro de transacción,
--         así que se ejecutan DESPUÉS del COMMIT)
-- ─────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    RAISE NOTICE 'PASO 3: Los índices se crean DESPUÉS del COMMIT (CONCURRENTLY no funciona en transacciones)';
    RAISE NOTICE 'PASO 3: Ejecutar: psql -f 02_indexes.sql DESPUÉS del commit de este script';
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 4: Crear triggers y funciones
-- ─────────────────────────────────────────────────────────────────────────
-- \i 03_triggers.sql  -- Ejecutar por separado para claridad
-- \i 04_functions.sql

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 5: Migrar historial de n8n_chat_histories a tabla usuarios
-- ESTRATEGIA: Extraer números únicos del session_id y crear perfiles mínimos
-- ─────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    v_empresa_id UUID := 'a0000000-0000-0000-0000-000000000001'; -- ZURA Solutions
    v_sesion_id  TEXT;
    v_count      INT := 0;
BEGIN
    -- n8n_chat_histories usa session_id = numero_limpio (sin @s.whatsapp.net)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'n8n_chat_histories') THEN
        FOR v_sesion_id IN
            SELECT DISTINCT session_id
            FROM n8n_chat_histories
            WHERE session_id IS NOT NULL
              AND session_id != ''
        LOOP
            -- Crear usuario mínimo a partir del session_id (es el número de WhatsApp)
            INSERT INTO usuarios (
                empresa_id,
                numero_whatsapp,
                numero_limpio,
                estado_lead
            ) VALUES (
                v_empresa_id,
                v_sesion_id,
                regexp_replace(v_sesion_id, '@[^@]+$', ''),
                'contactado'   -- ya habló con el bot → mínimo 'contactado'
            )
            ON CONFLICT (empresa_id, numero_limpio) DO NOTHING;

            -- Crear sesión correspondiente
            INSERT INTO sesiones (
                usuario_id,
                empresa_id,
                session_key,
                estado
            )
            SELECT
                u.id,
                v_empresa_id,
                v_sesion_id,
                'activa'
            FROM usuarios u
            WHERE u.empresa_id = v_empresa_id
              AND u.numero_limpio = regexp_replace(v_sesion_id, '@[^@]+$', '')
            ON CONFLICT (session_key) DO NOTHING;

            v_count := v_count + 1;
        END LOOP;

        RAISE NOTICE 'PASO 5: Migrados % usuarios desde n8n_chat_histories', v_count;
    ELSE
        RAISE NOTICE 'PASO 5: n8n_chat_histories no existe, saltando migración de usuarios';
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 6: Verificar config_negocio tiene los valores correctos
-- ─────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    v_empresa_id UUID := 'a0000000-0000-0000-0000-000000000001';
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM config_negocio WHERE empresa_id = v_empresa_id;
    IF v_count < 5 THEN
        RAISE WARNING 'PASO 6: Solo % campos en config_negocio. Revisar datos semilla.', v_count;
    ELSE
        RAISE NOTICE 'PASO 6: config_negocio tiene % campos OK', v_count;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PASO 7: Verificaciones post-migración
-- ─────────────────────────────────────────────────────────────────────────

SELECT 'empresas'           AS tabla, COUNT(*) AS filas FROM empresas
UNION ALL
SELECT 'instancias_whatsapp',          COUNT(*) FROM instancias_whatsapp
UNION ALL
SELECT 'config_negocio',               COUNT(*) FROM config_negocio
UNION ALL
SELECT 'usuarios',                     COUNT(*) FROM usuarios
UNION ALL
SELECT 'sesiones',                     COUNT(*) FROM sesiones
UNION ALL
SELECT 'citas',                        COUNT(*) FROM citas
UNION ALL
SELECT 'mensajes',                     COUNT(*) FROM mensajes
UNION ALL
SELECT 'audit_log',                    COUNT(*) FROM audit_log
UNION ALL
SELECT 'error_log',                    COUNT(*) FROM error_log;

-- ─────────────────────────────────────────────────────────────────────────
-- COMMIT (si todo está OK)
-- ─────────────────────────────────────────────────────────────────────────

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────
-- POST-COMMIT: Crear índices CONCURRENTLY (no bloquean)
-- Ejecutar MANUALMENTE después del commit:
-- ─────────────────────────────────────────────────────────────────────────

-- \i 02_indexes.sql

-- ─────────────────────────────────────────────────────────────────────────
-- ROLLBACK PLAN
-- Si algo falla antes del COMMIT, ejecutar:
--   ROLLBACK;
-- Las tablas nuevas se eliminan automáticamente (transacción revertida).
-- Las tablas de n8n (n8n_chat_histories etc.) no se tocan → intactas.
-- ─────────────────────────────────────────────────────────────────────────
