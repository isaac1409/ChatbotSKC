# Guía de Implementación — Paso a Paso
> ChatbotSKC | Tiempo total estimado: 60–90 min | Downtime requerido: ~0

---

## ANTES DE EMPEZAR: Responde estas preguntas

- ¿Tienes acceso a Easypanel ahora mismo? → Sí/No
- ¿Tienes acceso a n8n admin? → Sí/No
- ¿Tienes las credenciales de PostgreSQL (host, usuario, password)? → Sí/No
- ¿El chatbot está siendo usado en este momento? → Si sí, espera horario de baja actividad

---

## PASO 1 — BACKUP (5 min, con producción ACTIVA)

**¿Qué respaldar?**
- La base de datos que usa n8n (donde están los chat histories)
- No necesitas respaldar evolution-api-db (no la vas a tocar)

**Cómo hacerlo en Easypanel:**
```
Easypanel → Postgres (el de n8n) → Backups → Create Backup
```
O desde psql:
```bash
pg_dump -U postgres -d <nombre_bd_n8n> > backup_n8n_$(date +%Y%m%d).sql
```

**Checkpoint:** Verifica que el archivo de backup tiene contenido (no está vacío).

---

## PASO 2 — CREAR LA BASE DE DATOS NUEVA (10 min, con producción ACTIVA)

Esta es una base de datos COMPLETAMENTE NUEVA. No toca nada existente.

**En Easypanel:**
```
Easypanel → + New Service → PostgreSQL
  Nombre: bot-citas-db
  Version: 15
  Usuario: postgres (o el que prefieras)
  Password: [genera uno seguro]
```

**Anota estas credenciales — las necesitarás en el Paso 4:**
- Host: (interno Easypanel, algo como `bot-citas-db`)
- Puerto: 5432
- Base de datos: postgres (o el nombre que pusiste)
- Usuario: postgres
- Password: [el que pusiste]

**Checkpoint:** Easypanel muestra el servicio en verde (Running).

---

## PASO 3 — EJECUTAR LOS ARCHIVOS SQL (20 min, con producción ACTIVA)

**ORDEN OBLIGATORIO: 01 → 02 → 03 → 04**
El 05_migration.sql y 06_test_fixtures.sql NO se ejecutan en producción (son para migración desde sistema viejo y para testing).

**Cómo ejecutar:**

Opción A — Desde Easypanel (más fácil):
```
Easypanel → bot-citas-db → Connect → SQL Editor
```
Copiar y pegar el contenido de cada archivo en orden.

Opción B — Desde psql:
```bash
psql -h <host> -U postgres -d postgres -f database/01_schema_ddl.sql
psql -h <host> -U postgres -d postgres -f database/02_indexes.sql
psql -h <host> -U postgres -d postgres -f database/03_triggers.sql
psql -h <host> -U postgres -d postgres -f database/04_functions.sql
```

**Checkpoint después de cada archivo:** No debe haber errores en rojo. Avisos (NOTICE) son normales.

**Después de ejecutar 01_schema_ddl.sql, actualiza los valores reales en config_negocio:**
```sql
UPDATE config_negocio SET valor = 'TU_NUMERO_REAL' WHERE campo = 'numero_admin';
UPDATE config_negocio SET valor = 'TU_CORREO_REAL' WHERE campo = 'correo_admin';
UPDATE config_negocio SET valor = 'TU_GRUPO_WA_REAL' WHERE campo = 'grupo_whatsapp';
-- Si usas modo prueba, cambia a 'true':
UPDATE config_negocio SET valor = 'true' WHERE campo = 'modo_prueba';
```

---

## PASO 4 — IMPORTAR EL WORKFLOW EN n8n (15 min)

**IMPORTANTE: NO borres el workflow viejo. Los dos pueden coexistir.**

1. En n8n: `Settings → Import from file → Selecciona n8n/Chatbot_Principal_v3.json`
2. El workflow se importa como INACTIVO (no empieza a procesar mensajes todavía)
3. Configura las credenciales en el workflow nuevo:
   - PostgreSQL: apunta a `bot-citas-db` (host, puerto, usuario, password del Paso 2)
   - OpenAI: reutiliza la misma credencial que el workflow viejo
   - Google Calendar: reutiliza la misma credencial que el workflow viejo
   - Evolution API: reutiliza la misma credencial que el workflow viejo

**Checkpoint:** Todas las credenciales muestran ✓ verde en el workflow importado.

---

## PASO 5 — PRUEBA SIN AFECTAR USUARIOS (20 min)

**Con modo_prueba = 'true' en config_negocio, el bot solo responde al número admin.**

1. Activa el workflow nuevo en n8n (toggle ON)
2. En Evolution API, el webhook no cambia — ambos workflows pueden recibir el mismo webhook, pero el nuevo tiene su propia lógica de idempotencia
3. Envía un mensaje de WhatsApp DESDE TU NÚMERO (el numero_admin)
4. Verifica en bot-citas-db que se creó un registro en la tabla `mensajes`
5. Verifica que el bot responde correctamente
6. Intenta agendar una cita de prueba
7. Verifica que aparece tanto en Google Calendar como en la tabla `citas`

**Si todo funciona:**
```sql
UPDATE config_negocio SET valor = 'false' WHERE campo = 'modo_prueba';
```
El bot ya responde a todos los usuarios.

---

## PASO 6 — SWITCH A WORKFLOW NUEVO (5 min)

Una vez validado el workflow nuevo:
1. El workflow nuevo ya está activo y procesando todos los mensajes
2. El workflow viejo puede quedar activo como respaldo por 7 días
3. Después de 7 días sin incidentes: desactívalo (no lo borres)

---

## Resumen de lo que cambias

| Qué | Acción |
|-----|--------|
| Easypanel | Crear `bot-citas-db` |
| SQL | Ejecutar 01, 02, 03, 04 en `bot-citas-db` |
| n8n | Importar `Chatbot_Principal_v3.json` + configurar credenciales |
| config_negocio | Actualizar número admin, correo, grupo WA |

| Qué | NO tocas |
|-----|---------|
| evolution-api | No tocar |
| evolution-api-db | No tocar |
| n8n base de datos interna | No tocar |
| Google Calendar | No tocar |
| Google Sheets | No tocar (queda como respaldo) |
| Workflow viejo | No borrar (desactivar después de 7 días) |
