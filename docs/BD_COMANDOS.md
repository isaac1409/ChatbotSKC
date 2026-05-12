# Comandos útiles — Base de datos `bot_citas`

> Referencia rápida para operaciones comunes en producción.
> Para queries de monitoreo y diagnóstico ver también: `monitoring/queries_debug.sql`

---

## Conexión

```bash
# Desde Easypanel Query Console: siempre conectar a bot_citas antes de cualquier comando
\c bot_citas

# Confirmar en qué base estás
SELECT current_database();

# Listar tablas del schema público
\dt public.*

# Ver columnas de una tabla
\d config_negocio
\d usuarios
\d citas
```

---

## Config del negocio

```sql
-- Ver toda la config
SELECT campo, valor FROM config_negocio ORDER BY campo;

-- Buscar placeholders sin reemplazar
SELECT campo, valor FROM config_negocio WHERE valor LIKE '%REEMPLAZAR%';

-- Actualizar un campo
UPDATE config_negocio SET valor = 'NUEVO_VALOR' WHERE campo = 'nombre_campo';

-- Campos disponibles:
--   nombre_empresa      → nombre del negocio
--   nombre_agente       → nombre del bot (ej: Nova)
--   horario_inicio      → ej: 10:00 AM
--   horario_fin         → ej: 5:00 PM
--   duracion_reunion    → duración en minutos (ej: 30)
--   modo_prueba         → 'true' = solo responde al numero_admin
--   numero_admin        → número WA del admin (sin + ni espacios, ej: 5213349816581)
--   correo_admin        → correo para notificaciones Gmail
--   grupo_whatsapp      → ID del grupo WA para notificaciones (ej: 120363...@g.us)
```

### Toggle modo prueba
```sql
-- Activar modo prueba (solo responde al admin)
UPDATE config_negocio SET valor = 'true'  WHERE campo = 'modo_prueba';

-- Desactivar para producción (responde a todos)
UPDATE config_negocio SET valor = 'false' WHERE campo = 'modo_prueba';
```

---

## Usuarios

```sql
-- Ver todos los usuarios
SELECT numero_limpio, nombre, estado_lead, baneado, intentos_fallidos, created_at
FROM usuarios ORDER BY created_at DESC;

-- Buscar usuario por número
SELECT * FROM usuarios WHERE numero_limpio = '521XXXXXXXXXX';

-- Ver usuarios baneados activos
SELECT numero_limpio, nombre, intentos_fallidos, baneado_hasta
FROM usuarios
WHERE baneado = true AND (baneado_hasta IS NULL OR baneado_hasta > NOW());

-- Desbanear a alguien manualmente
UPDATE usuarios SET baneado = false, baneado_hasta = NULL, intentos_fallidos = 0
WHERE numero_limpio = '521XXXXXXXXXX';

-- Resetear intentos fallidos (sin desbanear)
UPDATE usuarios SET intentos_fallidos = 0
WHERE numero_limpio = '521XXXXXXXXXX';

-- Banear manualmente (ban 24h)
UPDATE usuarios SET baneado = true, baneado_hasta = NOW() + INTERVAL '24 hours'
WHERE numero_limpio = '521XXXXXXXXXX';
```

---

## Citas

```sql
-- Ver citas activas (no canceladas)
SELECT c.titulo, c.inicio AT TIME ZONE 'America/Mexico_City' AS inicio_mx,
       c.estado, c.google_event_id, u.numero_limpio, u.nombre
FROM citas c JOIN usuarios u ON c.usuario_id = u.id
WHERE c.estado NOT IN ('cancelada')
ORDER BY c.inicio DESC;

-- Ver citas del día de hoy
SELECT c.titulo, c.inicio AT TIME ZONE 'America/Mexico_City' AS hora,
       c.estado, u.nombre, u.numero_limpio
FROM citas c JOIN usuarios u ON c.usuario_id = u.id
WHERE DATE(c.inicio AT TIME ZONE 'America/Mexico_City') = CURRENT_DATE
ORDER BY c.inicio;

-- Ver citas de los próximos 7 días
SELECT c.titulo, c.inicio AT TIME ZONE 'America/Mexico_City' AS inicio_mx,
       c.estado, u.nombre
FROM citas c JOIN usuarios u ON c.usuario_id = u.id
WHERE c.inicio BETWEEN NOW() AND NOW() + INTERVAL '7 days'
  AND c.estado NOT IN ('cancelada')
ORDER BY c.inicio;

-- Cancelar una cita manualmente (usar google_event_id para identificarla)
UPDATE citas SET estado = 'cancelada'
WHERE google_event_id = 'ID_DEL_EVENTO_GCAL';

-- Marcar cita como completada
UPDATE citas SET estado = 'completada'
WHERE google_event_id = 'ID_DEL_EVENTO_GCAL';

-- Verificar que no hay citas solapadas (debe devolver 0 filas)
SELECT a.id, b.id, a.inicio, b.inicio
FROM citas a JOIN citas b ON a.id < b.id
  AND a.empresa_id = b.empresa_id
  AND tstzrange(a.inicio, a.fin, '[)') && tstzrange(b.inicio, b.fin, '[)')
WHERE a.estado NOT IN ('cancelada') AND b.estado NOT IN ('cancelada');
```

---

## Mensajes e idempotencia

```sql
-- Ver últimos mensajes procesados
SELECT key_id, direccion, LEFT(contenido, 80) AS contenido, procesado, created_at
FROM mensajes ORDER BY created_at DESC LIMIT 20;

-- Verificar que no hay key_id duplicados (debe devolver 0 filas)
SELECT key_id, COUNT(*) FROM mensajes GROUP BY key_id HAVING COUNT(*) > 1;

-- Forzar reprocesamiento de un mensaje (si quedó atascado)
DELETE FROM mensajes WHERE key_id = 'KEY_ID_DEL_MENSAJE';
-- Nota: borra el registro de idempotencia; el próximo webhook del mismo key_id se procesa de nuevo
```

---

## Error log

```sql
-- Ver errores no resueltos
SELECT error_code, origen, mensaje, created_at
FROM error_log WHERE resuelto = false
ORDER BY created_at DESC LIMIT 20;

-- Top errores de la última semana
SELECT error_code, origen, COUNT(*) AS veces, MAX(created_at) AS ultimo
FROM error_log WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY error_code, origen ORDER BY veces DESC;

-- Marcar errores como resueltos
UPDATE error_log SET resuelto = true WHERE resuelto = false AND error_code = 'CODIGO';

-- Marcar todos los errores como resueltos
UPDATE error_log SET resuelto = true WHERE resuelto = false;

-- Limpiar errores viejos (más de 30 días)
DELETE FROM error_log WHERE created_at < NOW() - INTERVAL '30 days';
```

---

## Salud general (snapshot rápido)

```sql
SELECT
    (SELECT COUNT(*) FROM usuarios)                                      AS usuarios_total,
    (SELECT COUNT(*) FROM usuarios WHERE baneado = true)                 AS usuarios_baneados,
    (SELECT COUNT(*) FROM citas WHERE estado NOT IN ('cancelada'))       AS citas_activas,
    (SELECT COUNT(*) FROM mensajes WHERE created_at > NOW()-INTERVAL '24h') AS mensajes_hoy,
    (SELECT COUNT(*) FROM error_log WHERE resuelto = false)              AS errores_pendientes;
```

---

## Índices (verificar que existen)

```sql
-- Listar todos los índices de la BD
SELECT indexname, tablename, indexdef
FROM pg_indexes WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- Verificar índices críticos específicos
SELECT indexname FROM pg_indexes
WHERE indexname IN (
    'idx_mensajes_key_id',
    'idx_citas_overlap_empresa',
    'idx_usuarios_baneados_activos'
);
-- Debe devolver 3 filas. Si faltan → ejecutar INSTALL_parte2.sql
```

---

## Mantenimiento

```sql
-- Tamaño de cada tabla
SELECT relname AS tabla,
       pg_size_pretty(pg_total_relation_size(relid)) AS tamanio_total
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- VACUUM manual (liberar espacio después de muchos DELETEs)
VACUUM ANALYZE mensajes;
VACUUM ANALYZE error_log;

-- Ver instancia WA registrada
SELECT id AS empresa_id, evolution_instance_name, activa FROM instancias_whatsapp;
```
