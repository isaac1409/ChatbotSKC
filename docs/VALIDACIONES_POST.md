# Validaciones Post-Implementación
> Cómo verificar que todo funciona SIN afectar usuarios reales

---

## ANTES DE ABRIR A USUARIOS: Checklist de 6 pruebas

Ejecuta estas pruebas con `modo_prueba = 'true'` en config_negocio.
Solo tu número (numero_admin) recibirá respuestas.

---

### Prueba 1 — La BD tiene las tablas correctas
```sql
-- Conectarte a bot-citas-db y ejecutar:
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
```
**Debe mostrar:** audit_log, citas, config_negocio, empresas, error_log,
instancias_whatsapp, mensajes, metricas_diarias, sesiones, usuarios

---

### Prueba 2 — La config está cargada
```sql
SELECT campo, valor FROM config_negocio
WHERE empresa_id = 'a0000000-0000-0000-0000-000000000001'
ORDER BY campo;
```
**Debe mostrar** los 9 campos con tus valores reales (no los `REEMPLAZAR_CON_*`).

---

### Prueba 3 — El bot responde mensajes
1. Envía "Hola" desde tu número de WhatsApp (el numero_admin)
2. Espera respuesta del bot (< 10 segundos)

**Verifica en BD:**
```sql
SELECT numero_limpio, nombre, created_at FROM usuarios ORDER BY created_at DESC LIMIT 5;
```
**Debe aparecer** tu número en la tabla usuarios.

---

### Prueba 4 — La idempotencia funciona (no procesa duplicados)
1. Envía el mismo mensaje dos veces rápido
2. El bot debe responder solo UNA vez

**Verifica en BD:**
```sql
SELECT key_id, COUNT(*) FROM mensajes GROUP BY key_id HAVING COUNT(*) > 1;
```
**Debe retornar 0 filas** (ningún key_id aparece dos veces).

---

### Prueba 5 — Agendar una cita funciona
1. Pídele al bot que agente una cita para mañana
2. El bot debe preguntar hora, nombre, etc.
3. Confirma la cita

**Verifica en Google Calendar:** el evento debe aparecer.

**Verifica en BD:**
```sql
SELECT titulo, inicio, fin, estado, google_event_id FROM citas ORDER BY created_at DESC LIMIT 3;
```
**Debe aparecer** la cita con `estado = 'pendiente'` y `google_event_id` no nulo.

---

### Prueba 6 — El workflow viejo sigue funcionando (opcional, si hay usuarios activos)
1. Desactiva el workflow nuevo temporalmente en n8n
2. Envía un mensaje desde otro número
3. El workflow viejo debe responder
4. Reactiva el workflow nuevo

---

## Cuando TODAS las pruebas pasan:
```sql
UPDATE config_negocio SET valor = 'false' WHERE campo = 'modo_prueba';
```
El bot está en producción completa.

---

## Queries de monitoreo diario (primeros 7 días)

```sql
-- Errores no resueltos de hoy
SELECT workflow_name, node_name, error_message, created_at
FROM error_log
WHERE resuelto = false AND DATE(created_at) = CURRENT_DATE
ORDER BY created_at DESC;

-- Mensajes procesados hoy
SELECT COUNT(*) AS total, direccion FROM mensajes
WHERE DATE(created_at) = CURRENT_DATE GROUP BY direccion;

-- Citas agendadas hoy
SELECT titulo, inicio, estado FROM citas
WHERE DATE(created_at) = CURRENT_DATE ORDER BY inicio;
```
