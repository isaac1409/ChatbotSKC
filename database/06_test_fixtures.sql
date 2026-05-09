-- ═══════════════════════════════════════════════════════════════════════════
-- TEST FIXTURES & QUERIES DE AUDITORÍA — ChatbotSKC
-- ⚠️  SOLO EJECUTAR EN AMBIENTE DE DESARROLLO/STAGING
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- FIXTURE: usuarios de prueba
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO usuarios (id, empresa_id, numero_whatsapp, numero_limpio, nombre, email, empresa_nombre, servicio_interes, estado_lead)
VALUES
    ('b0000001-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
     '5214921000001@s.whatsapp.net', '5214921000001',
     'Ana García', 'ana@empresa.com', 'TechCorp MX', 'Landing page', 'calificado'),

    ('b0000001-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001',
     '5214921000002@s.whatsapp.net', '5214921000002',
     'Carlos López', 'carlos@startup.io', 'Startup IO', 'Automatización', 'nuevo'),

    ('b0000001-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001',
     '5214921000003@s.whatsapp.net', '5214921000003',
     'María Rodríguez', null, null, 'Sitio web', 'convertido'),

    -- Usuario baneado para probar filtro
    ('b0000001-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001',
     '5214921000004@s.whatsapp.net', '5214921000004',
     'Usuario Baneado', null, null, null, 'nuevo')
ON CONFLICT (empresa_id, numero_limpio) DO NOTHING;

UPDATE usuarios SET baneado = true, baneado_hasta = NOW() + INTERVAL '23 hours', intentos_fallidos = 3
WHERE id = 'b0000001-0000-0000-0000-000000000004';

-- ─────────────────────────────────────────────────────────────────────────
-- FIXTURE: sesiones de prueba
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO sesiones (usuario_id, empresa_id, session_key, estado, ultimo_mensaje_at)
VALUES
    ('b0000001-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
     '5214921000001', 'activa', NOW() - INTERVAL '2 hours'),
    ('b0000001-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001',
     '5214921000003', 'completada', NOW() - INTERVAL '1 day')
ON CONFLICT (session_key) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────
-- FIXTURE: citas de prueba (próximas y pasadas)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO citas (id, empresa_id, usuario_id, google_event_id, google_calendar_id, titulo, descripcion, inicio, fin, estado)
VALUES
    -- Cita futura confirmada (para test de recordatorio)
    ('c0000001-0000-0000-0000-000000000001',
     'a0000000-0000-0000-0000-000000000001',
     'b0000001-0000-0000-0000-000000000003',
     'gcal_event_test_001', 'contacto.skcia@gmail.com',
     'María Rodríguez — TechCorp',
     'Servicio: Landing page. Problema: Sin presencia web',
     NOW() + INTERVAL '20 hours', NOW() + INTERVAL '20 hours 30 minutes',
     'pendiente'),

    -- Cita futura para probar overlap
    ('c0000001-0000-0000-0000-000000000002',
     'a0000000-0000-0000-0000-000000000001',
     'b0000001-0000-0000-0000-000000000001',
     'gcal_event_test_002', 'contacto.skcia@gmail.com',
     'Ana García — TechCorp MX',
     'Servicio: Sitio web. Problema: Rediseño',
     NOW() + INTERVAL '3 days',
     NOW() + INTERVAL '3 days 30 minutes',
     'pendiente'),

    -- Cita pasada completada (para métricas)
    ('c0000001-0000-0000-0000-000000000003',
     'a0000000-0000-0000-0000-000000000001',
     'b0000001-0000-0000-0000-000000000001',
     'gcal_event_test_003', 'contacto.skcia@gmail.com',
     'Ana García — TechCorp MX',
     'Servicio: Landing page. Problema: Sin leads',
     NOW() - INTERVAL '5 days',
     NOW() - INTERVAL '5 days' + INTERVAL '30 minutes',
     'completada'),

    -- Cita cancelada (para probar historial)
    ('c0000001-0000-0000-0000-000000000004',
     'a0000000-0000-0000-0000-000000000001',
     'b0000001-0000-0000-0000-000000000002',
     'gcal_event_test_004', 'contacto.skcia@gmail.com',
     'Carlos López — Startup IO',
     'Servicio: Automatización',
     NOW() - INTERVAL '2 days',
     NOW() - INTERVAL '2 days' + INTERVAL '30 minutes',
     'cancelada')
ON CONFLICT (google_event_id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────
-- FIXTURE: mensajes de prueba (idempotencia)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO mensajes (empresa_id, usuario_id, key_id, direccion, tipo, contenido, procesado)
VALUES
    ('a0000000-0000-0000-0000-000000000001', 'b0000001-0000-0000-0000-000000000001',
     'wa_key_test_001', 'entrada', 'texto', 'Hola, quiero agendar una cita', true),
    ('a0000000-0000-0000-0000-000000000001', 'b0000001-0000-0000-0000-000000000001',
     'wa_key_test_002', 'salida', 'texto', '¡Hola Ana! Claro que sí...', true),
    -- Mensaje no procesado (para simular fallo)
    ('a0000000-0000-0000-0000-000000000001', 'b0000001-0000-0000-0000-000000000002',
     'wa_key_test_003', 'entrada', 'texto', 'Necesito automatizar mi negocio', false)
ON CONFLICT (key_id) DO NOTHING;

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────
-- TEST SUITE: Ejecutar estas queries para validar el sistema
-- ─────────────────────────────────────────────────────────────────────────

-- TEST 1: Idempotencia de mensajes
DO $$
BEGIN
    -- Intentar insertar mensaje duplicado → debe fallar por UNIQUE
    BEGIN
        INSERT INTO mensajes (empresa_id, usuario_id, key_id, direccion, tipo, contenido)
        VALUES (
            'a0000000-0000-0000-0000-000000000001',
            'b0000001-0000-0000-0000-000000000001',
            'wa_key_test_001', -- key_id que ya existe
            'entrada', 'texto', 'Mensaje duplicado'
        );
        RAISE EXCEPTION 'TEST 1 FALLÓ: Debería haber lanzado error de UNIQUE';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'TEST 1 PASÓ: Idempotencia funciona correctamente';
    END;
END;
$$;

-- TEST 2: Overlap de citas
DO $$
DECLARE
    v_inicio TIMESTAMPTZ := NOW() + INTERVAL '20 hours';  -- mismo horario que fixture c0000001
    v_fin    TIMESTAMPTZ := NOW() + INTERVAL '20 hours 30 minutes';
BEGIN
    BEGIN
        INSERT INTO citas (empresa_id, usuario_id, google_event_id, titulo, inicio, fin)
        VALUES (
            'a0000000-0000-0000-0000-000000000001',
            'b0000001-0000-0000-0000-000000000002',
            'gcal_overlap_test_001',
            'Cita que overlap',
            v_inicio, v_fin
        );
        RAISE EXCEPTION 'TEST 2 FALLÓ: Debería haber detectado overlap';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        RAISE NOTICE 'TEST 2 PASÓ: Trigger de overlap funciona correctamente';
    END;
END;
$$;

-- TEST 3: Función upsert_usuario
DO $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT upsert_usuario(
        'a0000000-0000-0000-0000-000000000001'::UUID,
        '5214921099999@s.whatsapp.net',
        'Test Usuario Nuevo',
        'test@email.com',
        'TestCorp',
        'IA Assistant',
        'Necesito chatbot'
    ) INTO v_result;

    IF (v_result->>'es_nuevo')::BOOLEAN = true THEN
        RAISE NOTICE 'TEST 3 PASÓ: upsert_usuario creó nuevo usuario, id=%', v_result->>'id';
    ELSE
        RAISE NOTICE 'TEST 3 PASÓ: upsert_usuario actualizó usuario existente';
    END IF;

    -- Limpiar
    DELETE FROM usuarios WHERE numero_limpio = '5214921099999';
END;
$$;

-- TEST 4: Función buscar_slots_disponibles
DO $$
DECLARE
    v_slot RECORD;
    v_count INT := 0;
BEGIN
    FOR v_slot IN
        SELECT * FROM buscar_slots_disponibles(
            'a0000000-0000-0000-0000-000000000001'::UUID,
            NOW(),
            NOW() + INTERVAL '3 days',
            30,
            '10:00:00'::TIME,
            '17:00:00'::TIME,
            5
        )
    LOOP
        v_count := v_count + 1;
    END LOOP;

    IF v_count > 0 THEN
        RAISE NOTICE 'TEST 4 PASÓ: buscar_slots_disponibles retornó % slots', v_count;
    ELSE
        RAISE WARNING 'TEST 4: Sin slots disponibles (puede ser fin de semana o todas las horas ocupadas)';
    END IF;
END;
$$;

-- TEST 5: Validar usuario baneado
DO $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT validar_puede_agendar(
        'a0000000-0000-0000-0000-000000000001'::UUID,
        'b0000001-0000-0000-0000-000000000004'::UUID
    ) INTO v_result;

    IF (v_result->>'puede')::BOOLEAN = false AND v_result->>'razon' = 'usuario_baneado' THEN
        RAISE NOTICE 'TEST 5 PASÓ: Usuario baneado bloqueado correctamente';
    ELSE
        RAISE EXCEPTION 'TEST 5 FALLÓ: Usuario baneado no fue bloqueado. Resultado: %', v_result;
    END IF;
END;
$$;

-- TEST 6: Función get_config_empresa
DO $$
DECLARE
    v_config JSONB;
BEGIN
    SELECT get_config_empresa('a0000000-0000-0000-0000-000000000001'::UUID) INTO v_config;

    IF v_config ? 'nombre_empresa' AND v_config ? 'horario_inicio' THEN
        RAISE NOTICE 'TEST 6 PASÓ: get_config_empresa retorna config completa';
        RAISE NOTICE '  nombre_empresa=%', v_config->>'nombre_empresa';
        RAISE NOTICE '  horario_inicio=%', v_config->>'horario_inicio';
    ELSE
        RAISE EXCEPTION 'TEST 6 FALLÓ: Config incompleta: %', v_config;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- RESUMEN FINAL
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    RAISE NOTICE '═══════════════════════════════════════';
    RAISE NOTICE 'TEST SUITE COMPLETADO';
    RAISE NOTICE 'Revisar los mensajes NOTICE arriba.';
    RAISE NOTICE 'Buscar "FALLÓ" para identificar problemas.';
    RAISE NOTICE '═══════════════════════════════════════';
END;
$$;
