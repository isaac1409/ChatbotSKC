# Troubleshooting — ChatbotSKC

## Diagnóstico rápido

```bash
# Estado general del sistema
./monitoring/health_check.sh

# Ver últimos errores en BD
psql -c "SELECT error_code, origen, mensaje, created_at FROM error_log WHERE resuelto=false ORDER BY created_at DESC LIMIT 20;"

# Ver logs de n8n (Easypanel)
# Easypanel → n8n → Logs
```

---

## Problemas comunes

### El bot no responde mensajes

**Síntomas:** Los mensajes llegan a Evolution API pero n8n no los procesa.

**Verificar:**
1. El workflow `Chatbot_Principal_v3` está activo (toggle ON)
2. La URL del webhook en Evolution API apunta al dominio de n8n correcto:
   ```
   https://[n8n-dominio]/webhook/aa0cdd49-6d3b-4a28-a690-7be70d4ffe70
   ```
3. Evolution API puede alcanzar n8n (no hay firewall bloqueando)
4. Logs de n8n → Executions: ver si hay ejecuciones fallidas

**Fix rápido:**
```
Evolution API → Instances → SKC → Webhook → Update → pegar URL correcta
```

---

### El bot responde a sus propios mensajes (loop)

**Causa:** El nodo `IF fromMe` no está como primera condición, o `fromMe` no está evaluando correctamente.

**Fix:**
```javascript
// En el nodo IF, la condición debe ser:
$json.body.data.key.fromMe === false
// true output → continuar
// false output → No Action
```

---

### Mensajes duplicados (el bot responde dos veces)

**Causa A:** Webhook Response no está al inicio del workflow.
**Causa B:** Evolution API retransmitió porque n8n tardó >10s en responder.
**Causa C:** Redis buffer no está funcionando.

**Verificar:**
```sql
-- Ver si hay key_ids duplicados (no debe haber ninguno)
SELECT key_id, COUNT(*) FROM mensajes GROUP BY key_id HAVING COUNT(*) > 1;
```

**Fix:**
- Asegurarse de que el nodo `Webhook Response` es el segundo nodo (después del Webhook trigger)
- Verificar conectividad Redis: `redis-cli ping` → debe responder `PONG`

---

### Error en tool calling del AI Agent

**Síntoma:** El agente no agenda/cancela citas aunque el usuario lo pide.

**Causa más común:** Usar `gpt-4o-mini` en lugar de `gpt-4.1`. Mini falla silenciosamente en tool use.

**Fix:**
```
n8n → AI Agent node → Model → seleccionar gpt-4.1
```

**Verificar en logs:**
```
n8n → Executions → seleccionar ejecución → AI Agent → Output
Buscar: "tool_calls" en la respuesta del modelo
Si no hay tool_calls pero el usuario pidió agendar: el modelo equivocado está configurado
```

---

### Citas no aparecen en la tabla `citas`

**Causa A:** El nodo `Sync cita en BD` tiene credencial no asignada.
**Causa B:** `Revisar si se agendó` no está extrayendo `googleEventId` correctamente.

**Verificar:**
```sql
-- Ver últimas ejecuciones de Sync cita en BD
SELECT * FROM citas ORDER BY created_at DESC LIMIT 5;

-- Ver errores de ese nodo
SELECT * FROM error_log WHERE origen = 'chatbot_principal' ORDER BY created_at DESC LIMIT 10;
```

**Fix en `Revisar si se agendó`:**
```javascript
// El campo debe estar en intermediateSteps del AI Agent
const steps = $json.intermediateSteps || [];
const agendarStep = steps.find(s => s.action?.tool === 'agendar_cita');
const googleEventId = agendarStep?.observation?.id || null;
```

---

### `overlap de citas` — trigger lanza error al intentar agendar

**Síntoma:** n8n recibe `SQLSTATE P0001` al ejecutar `registrar_cita`.

**Esto es correcto** — el trigger detectó que hay otra cita en ese horario. El AI Agent debe manejar este error y proponer otro horario.

**Si los overlaps ocurren cuando no deberían:**
```sql
-- Verificar que el índice GiST existe
SELECT indexname FROM pg_indexes WHERE indexname = 'idx_citas_overlap_empresa';

-- Verificar overlap manualmente
SELECT a.id, b.id, a.inicio, b.inicio
FROM citas a JOIN citas b ON a.id < b.id
  AND a.empresa_id = b.empresa_id
  AND tstzrange(a.inicio, a.fin, '[)') && tstzrange(b.inicio, b.fin, '[)')
WHERE a.estado NOT IN ('cancelada') AND b.estado NOT IN ('cancelada');
```

---

### `Cargar config empresa` retorna 0 filas

**Causa:** La instancia `SKC` no está registrada en `instancias_whatsapp`.

**Fix:**
```sql
-- Verificar
SELECT * FROM instancias_whatsapp;

-- Si no hay filas, insertar:
INSERT INTO instancias_whatsapp (empresa_id, evolution_instance_name, activa)
VALUES (
  (SELECT id FROM empresas LIMIT 1),
  'SKC',
  true
);
```

---

### Recordatorio 24h no se envía

**Verificar:**
```sql
-- Hay citas próximas sin recordatorio?
SELECT * FROM v_proximas_citas WHERE inicio < NOW() + INTERVAL '25 hours' AND recordatorio_enviado = false;
```

**Causas:**
1. El workflow `Chatbot_Recordatorio_24h` no está activo
2. La credencial de Evolution API no está asignada en el nodo `Enviar recordatorio WA`
3. El `numero_whatsapp` en la tabla `usuarios` tiene formato incorrecto (debe ser `521XXXXXXXXXX@s.whatsapp.net`)

---

### `init_db.sh` falla con `extension "btree_gist" is not available`

**Fix:**
```sql
-- Requiere superuser en Easypanel
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Si no tienes permisos, pedirlo al admin de Easypanel o:
-- En Easypanel → PostgreSQL → Extensions → habilitar btree_gist
```

---

### Gmail OAuth2 — "invalid_grant"

**Causa:** El token de refresh expiró o fue revocado.

**Fix:**
```
1. n8n → Settings → Credentials → Gmail OAuth2
2. Borrar credencial
3. Crear nueva → autorizar de nuevo desde Google
```

---

### Métricas nocturnas fallan con "función no existe"

**Causa:** La función `calcular_metricas_diarias` no fue creada (falló `init_db.sh`).

**Fix:**
```bash
psql -f database/04_functions.sql
# Verificar:
psql -c "\df calcular_metricas_diarias"
```

---

## Queries de diagnóstico rápido

Ver archivo completo: [`monitoring/queries_debug.sql`](../monitoring/queries_debug.sql)

```sql
-- ¿El sistema está procesando mensajes?
SELECT COUNT(*) FROM mensajes WHERE created_at > NOW() - INTERVAL '1 hour';

-- ¿Hay errores sin resolver?
SELECT COUNT(*) FROM error_log WHERE resuelto = false;

-- ¿La config está bien cargada?
SELECT campo, valor FROM config_negocio
WHERE empresa_id = (SELECT empresa_id FROM instancias_whatsapp WHERE evolution_instance_name = 'SKC' LIMIT 1)
  AND valor LIKE '%REEMPLAZAR%';
-- Debe retornar 0 filas
```

---

## Resolver un error en `error_log`

```sql
-- Ver detalles del error
SELECT * FROM error_log WHERE id = 'UUID_DEL_ERROR';

-- Marcar como resuelto después de corregirlo
UPDATE error_log SET resuelto = true, resuelto_at = NOW()
WHERE id = 'UUID_DEL_ERROR';
```
