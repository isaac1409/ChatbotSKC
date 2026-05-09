# ChatbotSKC

Workflows de n8n para chatbots de WhatsApp con IA, desarrollados por **Innovasoft Solutions (SKC)**. El stack completo incluye agente conversacional con IA, gestión de citas en Google Calendar, base de datos PostgreSQL propia, y notificaciones multi-canal.

---

## Stack

| Capa | Tecnología |
|---|---|
| Orquestación | n8n 1.123.21 (Easypanel) |
| Mensajería | Evolution API v2.3.7 |
| IA principal | OpenAI gpt-4.1 (tool calling) |
| IA visión | OpenAI gpt-4o-mini |
| IA audio | Whisper |
| Calendario | Google Calendar (OAuth2) |
| Config dinámica | PostgreSQL `config_negocio` |
| Memoria conversacional | Postgres Chat Memory (`n8n_chat_histories`) |
| Buffer de mensajes | Redis |
| Base de datos | PostgreSQL 15 |
| Infraestructura | Easypanel |

---

## Estructura del repositorio

```
ChatbotSKC/
├── CLAUDE.md                        ← contexto para Claude Code
├── README.md                        ← este archivo
├── .env.example                     ← variables de entorno requeridas
├── docker-compose.yml               ← entorno local de desarrollo
│
├── database/                        ← SQL de la base de datos
│   ├── 01_schema_ddl.sql            ← DDL: tablas, tipos, índices, seeds
│   ├── 02_indexes.sql               ← Índices estratégicos (CONCURRENTLY)
│   ├── 03_triggers.sql              ← Triggers: overlap, audit, autobaneo
│   ├── 04_functions.sql             ← Funciones PL/pgSQL + 3 vistas
│   ├── 05_migration.sql             ← Migra historial → tabla usuarios
│   └── 06_test_fixtures.sql         ← Test suite (solo staging)
│
├── n8n/                             ← Workflows exportados de n8n
│   ├── Chatbot_Principal_v2.json    ← Workflow principal (importar a n8n)
│   ├── Chatbot_Recordatorio_24h.json ← Sub-workflow: recordatorio 24h
│   ├── Chatbot_Metricas_Nocturnas.json ← Sub-workflow: reporte diario 23:58
│   └── Chatbot_GCal_Sync.json       ← Sub-workflow: sincronizar GCal → BD
│
├── scripts/                         ← Scripts de operación
│   ├── init_db.sh                   ← Inicializar BD desde cero
│   ├── backup_db.sh                 ← Backup con rotación (últimos 7)
│   ├── test_db.sh                   ← Ejecutar test suite en staging
│   ├── cleanup_db.sh                ← Destruir tablas (solo dev)
│   └── cleanup_repo.sh              ← Eliminar carpetas legacy
│
├── monitoring/                      ← Monitoreo y diagnóstico
│   ├── queries_debug.sql            ← Queries de diagnóstico en producción
│   └── health_check.sh              ← Health check de todos los servicios
│
├── docs/                            ← Documentación técnica
│   ├── analysis/ANALISIS_SISTEMA.md ← Análisis crítico del sistema
│   ├── n8n/WORKFLOW_ARCHITECTURE.md ← Arquitectura de los 13 sub-módulos
│   └── rollout/PLAN_ROLLOUT.md      ← Plan de rollout día a día
│
└── workflows/                       ← Versiones legacy (referencia)
    └── Chatbot_Prod_V1.json
```

---

## Inicio rápido — Base de datos

```bash
# 1. Copiar variables de entorno
cp .env.example .env
# Editar .env con credenciales reales

# 2. Inicializar BD (ejecuta DDL + triggers + funciones + índices)
./scripts/init_db.sh

# 3. Migrar historial existente (n8n_chat_histories → usuarios)
psql -f database/05_migration.sql

# 4. Cargar config real (ver docs/rollout/PLAN_ROLLOUT.md paso 1.3)
```

## Inicio rápido — n8n

1. n8n → **Workflows** → `+` → **Import from file**
2. Importar `n8n/Chatbot_Principal_v2.json`
3. Reasignar credenciales (ver tabla abajo)
4. Importar y activar los 3 sub-workflows
5. Verificar con mensaje de prueba desde el número admin

---

## Credenciales a configurar tras importar

| Credencial | Tipo | Nodos |
|---|---|---|
| PostgreSQL | Host/DB/User/Pass | Todos los nodos Postgres |
| Google Calendar | OAuth2 | agendar_cita, cancelar_cita, consultar_citas |
| OpenAI | API Key | AI Agent, Analizar imagen, Transcribir audio |
| Redis | Host/Port/Pass | Buffer de mensajes |
| Evolution API | Header Auth (apikey) | HTTP Requests envío WA |

> ⚠️ Las credenciales no se transfieren al importar. Reasignarlas antes de activar.

---

## Sub-workflows

| Archivo | Trigger | Función |
|---|---|---|
| `Chatbot_Recordatorio_24h.json` | Cron `0 9 * * 1-5` | Envía WA a clientes con cita en las próximas 24h |
| `Chatbot_Metricas_Nocturnas.json` | Cron `58 23 * * *` | Calcula métricas del día y envía reporte al admin |
| `Chatbot_GCal_Sync.json` | Cron `*/30 * * * *` | Sincroniza cambios de GCal → tabla `citas` |

---

## Reglas del repositorio

- **No editar los `.json` a mano** — son exportaciones directas de n8n
- **No commitear credenciales** — se gestionan en Easypanel / n8n Credentials
- Un archivo por workflow, un workflow por cliente
- Siempre incluir número de versión: `Chatbot_[Cliente]_v[N].json`
- Commits en español: `feat:`, `fix:`, `docs:`, `chore:`

---

## Checklist antes de activar en producción

```
□ Credenciales reasignadas en todos los nodos
□ Config cargada en config_negocio (sin valores 'REEMPLAZAR_CON_...')
□ modo_prueba = true durante testing
□ Test suite pasó: ./scripts/test_db.sh
□ Health check: ./monitoring/health_check.sh
□ modo_prueba = false antes de activar
□ JSON commiteado en el repo antes de activar
□ Sub-workflows activos: Recordatorio, Métricas, GCal Sync
```

---

## Documentación técnica

- [`docs/analysis/ANALISIS_SISTEMA.md`](docs/analysis/ANALISIS_SISTEMA.md) — análisis crítico y comparativa
- [`docs/n8n/WORKFLOW_ARCHITECTURE.md`](docs/n8n/WORKFLOW_ARCHITECTURE.md) — arquitectura de los 13 sub-módulos
- [`docs/rollout/PLAN_ROLLOUT.md`](docs/rollout/PLAN_ROLLOUT.md) — plan de rollout día a día con validaciones y rollback
