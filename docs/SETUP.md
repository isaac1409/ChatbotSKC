# Guía de Setup — ChatbotSKC

## Prerequisitos

- Docker Desktop (para desarrollo local) o acceso a Easypanel (producción)
- PostgreSQL 15 con extensiones `pgcrypto` y `btree_gist`
- n8n 1.123.21
- Evolution API v2.3.7 configurada con una instancia activa
- Cuenta Google con Calendar + Gmail habilitados
- API key de OpenAI con acceso a `gpt-4.1` y `whisper-1`

---

## Desarrollo local (Docker Compose)

```bash
# 1. Clonar y preparar variables
git clone <repo>
cd ChatbotSKC
cp .env.example .env
# Editar .env con credenciales locales (password dev, etc.)

# 2. Levantar servicios
docker compose up -d
# Esto levanta: PostgreSQL 15, Redis 7, n8n 1.123.21

# 3. Inicializar la base de datos
./scripts/init_db.sh
# Ejecuta DDL, triggers, funciones, índices en orden

# 4. Verificar
docker compose ps      # todos healthy
psql -c "SELECT COUNT(*) FROM empresas;"   # debe retornar 1 (ZURA Solutions)

# 5. Abrir n8n
open http://localhost:5678
```

---

## Producción (Easypanel)

### Base de datos

```bash
# Conectarse al PostgreSQL de Easypanel (desde consola del servicio)
psql -U postgres -d bot_citas

# Verificar extensiones
SELECT * FROM pg_available_extensions WHERE name IN ('pgcrypto','btree_gist');

# Ejecutar DDL
\i /ruta/a/database/01_schema_ddl.sql
\i /ruta/a/database/03_triggers.sql
\i /ruta/a/database/04_functions.sql

# Índices CONCURRENTLY (fuera de transacción)
\i /ruta/a/database/02_indexes.sql

# Migrar historial de n8n_chat_histories
\i /ruta/a/database/05_migration.sql
```

### Configuración de la empresa

```sql
-- Actualizar con valores reales (reemplazar los REEMPLAZAR_CON_...)
UPDATE config_negocio SET valor = '+521XXXXXXXXXX'
WHERE campo = 'numero_admin';

UPDATE config_negocio SET valor = 'admin@empresa.com'
WHERE campo = 'correo_admin';

-- Verificar
SELECT campo, valor FROM config_negocio ORDER BY campo;
-- Ningún valor debe contener 'REEMPLAZAR_CON_'
```

---

## Importar workflows en n8n

### Workflow principal

1. n8n → **Workflows** → `+` → **Import from file**
2. Seleccionar `n8n/Chatbot_Principal_v2.json`
3. El workflow importa con `active: false` — NO activar aún

### Reasignar credenciales

Abrir el workflow importado y reasignar en cada nodo:

| Nodo | Credencial necesaria |
|---|---|
| Postgres Chat Memory | PostgreSQL (host, db, user, pass) |
| Verificar idempotencia | PostgreSQL |
| Cargar config empresa | PostgreSQL |
| Upsert usuario | PostgreSQL |
| Sync cita en BD | PostgreSQL |
| Transcribir audio | OpenAI (API key) |
| Analizar imagen | OpenAI (API key) |
| AI Agent | OpenAI (API key) |
| agendar_cita (tool) | Google Calendar (OAuth2) |
| cancelar_cita (tool) | Google Calendar (OAuth2) |
| consultar_citas (tool) | Google Calendar (OAuth2) |
| Buffer Redis | Redis (host, port, password) |
| Enviar respuesta | Evolution API (Header Auth, apikey) |
| Notificar admin/grupo | Evolution API |
| Notificar Gmail | Gmail (OAuth2) |

### Activar workflow

```
1. Probar con mensaje desde el número de admin
2. Verificar en psql: SELECT * FROM mensajes ORDER BY created_at DESC LIMIT 5;
3. Si todo OK → Toggle ON
```

### Sub-workflows

Importar en orden y reasignar credenciales en cada uno:
1. `n8n/Chatbot_Recordatorio_24h.json` — PostgreSQL + Evolution API
2. `n8n/Chatbot_Metricas_Nocturnas.json` — PostgreSQL + Evolution API
3. `n8n/Chatbot_GCal_Sync.json` — PostgreSQL + Google Calendar

---

## Google OAuth2 en n8n

1. n8n → **Settings** → **Credentials** → **Add Credential**
2. Tipo: **Google Calendar OAuth2 API**
3. Client ID y Client Secret desde Google Cloud Console:
   - APIs & Services → Credentials → OAuth 2.0 Client IDs
   - Authorized redirect URI: `https://[tu-n8n-dominio]/rest/oauth2-credential/callback`
4. Scope requerido: `https://www.googleapis.com/auth/calendar`
5. Autorizar → completar el flujo OAuth en el popup

---

## Variables de entorno por servicio (Easypanel)

### n8n

| Variable | Valor |
|---|---|
| `DB_TYPE` | `postgresdb` |
| `DB_POSTGRESDB_HOST` | hostname interno Easypanel |
| `DB_POSTGRESDB_DATABASE` | `bot_citas` |
| `DB_POSTGRESDB_USER` | `postgres` |
| `DB_POSTGRESDB_PASSWORD` | *** |
| `QUEUE_BULL_REDIS_HOST` | hostname interno Redis |
| `GENERIC_TIMEZONE` | `America/Mexico_City` |
| `N8N_ENCRYPTION_KEY` | string aleatorio 32+ chars |

### Evolution API

Configurar vía el panel de Easypanel del servicio Evolution API. La instancia `SKC` debe estar conectada (QR escaneado).

---

## Verificar instalación completa

```bash
./monitoring/health_check.sh
```

Debe mostrar `OK` en todos los componentes. Cualquier `FAIL` indica un problema a resolver antes de activar en producción.
