# Plan de Rollback — Si algo falla

---

## La regla de oro

El workflow viejo nunca se borra. Si algo explota, en 2 minutos puedes volver al estado anterior.

---

## Escenario A — Falló el SQL (durante Paso 3)

**Síntoma:** Error rojo al ejecutar los archivos SQL.

**Qué hacer:**
1. No pasa nada — bot-citas-db es nueva y está vacía, no afectó nada en producción
2. Lee el error (viene en rojo con descripción)
3. Si el error es "type already exists": la BD no estaba limpia, bórrala y vuelve a crearla
4. Easypanel → bot-citas-db → Delete → Recrear → volver al Paso 2

**Producción:** Nunca se afectó. El chatbot siguió funcionando durante todo este tiempo.

---

## Escenario B — El workflow nuevo no funciona (durante Paso 5)

**Síntoma:** El bot no responde, o da error, o responde mal.

**Qué hacer en 2 minutos:**
1. n8n → Workflow nuevo → Toggle OFF (desactivar)
2. n8n → Workflow viejo → Toggle ON (si lo desactivaste)
3. El bot vuelve a funcionar exactamente como antes

**Luego investiga:**
- n8n → Executions → ver el error del workflow nuevo
- Verifica que las credenciales de PostgreSQL apuntan a bot-citas-db (no a otra BD)
- Verifica que config_negocio tiene los valores correctos

---

## Escenario C — El bot respondió mal a usuarios reales

**Síntoma:** Usuarios se quejaron de respuestas incorrectas.

**Qué hacer:**
1. n8n → Workflow nuevo → Toggle OFF
2. n8n → Workflow viejo → Toggle ON
3. Avisa a los usuarios afectados si es necesario
4. Revisa la tabla `mensajes` para ver qué pasó:
   ```sql
   SELECT contenido, created_at FROM mensajes
   WHERE DATE(created_at) = CURRENT_DATE
   ORDER BY created_at DESC LIMIT 20;
   ```

---

## Escenario D — bot-citas-db se corrompió o perdió datos

**Síntoma:** Errores de conexión a bot-citas-db, o datos incorrectos.

**Qué hacer:**
1. n8n → Workflow nuevo → Toggle OFF (vuelves al workflow viejo)
2. bot-citas-db es solo una COPIA SINCRONIZADA — Google Calendar tiene todos los datos reales
3. Puedes recrear bot-citas-db desde cero (los datos de Google Calendar no se pierden)
4. Ejecutar de nuevo: Paso 2 → Paso 3 del GUIA_IMPLEMENTACION.md

---

## Lo que NUNCA se puede perder con este sistema

- **Google Calendar:** fuente de verdad de citas. Siempre ahí.
- **Historial de conversaciones (n8n_chat_histories):** en la BD de n8n. No se tocó.
- **Evolution API:** no se tocó. WhatsApp sigue funcionando.

El peor escenario posible es: bot-citas-db vacía + workflow nuevo desactivado = vuelves exactamente al estado de hoy.
