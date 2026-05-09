# ChatbotSKC — Briefing para Claude Code

## 🎯 Propósito del proyecto
Workflows de n8n para chatbots de WhatsApp con IA, desarrollados y mantenidos por
Innovasoft Solutions (SKC). El repo versiona los workflows exportados y la documentación
del stack. No hay código de aplicación — la lógica vive en n8n.

---

## 🏗️ Stack tecnológico

- **Orquestación:** n8n 1.123.21 (self-hosted en Easypanel)
- **Mensajería:** Evolution API v2.3.7
- **IA:** OpenAI gpt-4.1 (agente principal), gpt-4o-mini (visión), Whisper (audio)
- **Calendario:** Google Calendar (OAuth2)
- **Config dinámica:** PostgreSQL tabla `config_negocio` (migrado desde Google Sheets)
- **Memoria:** Postgres Chat Memory (n8n nativo)
- **Buffer:** Redis
- **Base de datos:** PostgreSQL 15
- **Infraestructura:** Easypanel — todos los servicios están hosteados ahí, sin Docker local

---

## 📁 Estructura del repositorio

```
ChatbotSKC/
├── CLAUDE.md / CLAUDE.MD      ← este archivo
├── README.md                  ← estructura completa del repo
├── CLEANUP.md                 ← checklist de rollout (5 fases)
├── .env.example               ← variables requeridas
├── docker-compose.yml         ← entorno local de desarrollo
├── database/                  ← SQL: DDL, índices, triggers, funciones, migración, tests
├── n8n/                       ← workflows exportados (importar directamente a n8n)
│   ├── Chatbot_Principal_v2.json
│   ├── Chatbot_Recordatorio_24h.json
│   ├── Chatbot_Metricas_Nocturnas.json
│   └── Chatbot_GCal_Sync.json
├── scripts/                   ← operación: init, backup, test, cleanup
├── monitoring/                ← queries de debug + health check
├── docs/                      ← arquitectura, setup, API contracts, troubleshooting
└── workflows/                 ← versiones legacy (referencia)
```

**Regla:** cada vez que se estabiliza una versión, exportar el workflow desde
n8n (Settings → Download) y commitear el JSON en `n8n/` con el número de versión.

---

## ✅ Convenciones

- Nombres de archivo de workflows: `Chatbot_[Cliente]_v[N].json`
- Commits en español: `feat:`, `fix:`, `docs:`, `chore:`
- Nunca commitear credenciales ni valores reales de producción
- Un workflow por archivo — no agrupar clientes en un solo JSON

---

## ⚠️ Zonas de NO tocar sin confirmación

- `n8n/*.json` y `workflows/*.json` — son exportaciones directas de n8n; editarlos a mano rompe el formato
- `database/*.sql` — cambios requieren revisión explícita y test suite antes de aplicar en producción

---

## 🔗 Servicios activos (Easypanel)

| Servicio | URL / acceso |
|---|---|
| n8n | https://[dominio-n8n] |
| Evolution API | https://[dominio-evolution]:8080 |
| PostgreSQL | interno Easypanel |
| Redis | interno Easypanel |

Las credenciales y variables de entorno se gestionan desde el panel de cada
servicio en Easypanel — no hay `.env` en este repo.

---

## 📌 Estado actual del proyecto

- **Fase:** Listo para rollout — pendiente de ejecutar en producción
- **Workflow en producción:** Chatbot_Isaac (1).json (legacy, en `chatbot_isaac_funcionando_en_prod/`)
- **Workflow nuevo:** `n8n/Chatbot_Principal_v2.json` — listo para importar, con:
  - Idempotencia por `key_id` en tabla `mensajes`
  - Config desde Postgres (reemplaza Google Sheets)
  - Sync de citas a tabla `citas` (Google Calendar + BD)
  - Upsert de usuario en paralelo
- **Sub-workflows generados:** Recordatorio 24h, Métricas Nocturnas, GCal Sync
- **BD lista:** `database/*.sql` — DDL + triggers + funciones + migración
- **Próximos pasos:**
  1. Ejecutar `./scripts/init_db.sh` en producción
  2. Actualizar `config_negocio` con valores reales
  3. Importar `Chatbot_Principal_v2.json` en n8n (ver `CLEANUP.md`)
  4. Ejecutar `./scripts/cleanup_repo.sh` para eliminar carpetas legacy
- **Blockers conocidos:** Gmail OAuth2 pendiente de configurar en n8n

> ⚠️ Actualizar esta sección cada vez que se retome el proyecto.

---

## 🧠 Contexto técnico importante

Leer antes de proponer cambios al workflow o a la configuración:
- `docs/ARCHITECTURE.md` — diagrama de componentes, flujo de datos, schema de BD
- `docs/TROUBLESHOOTING.md` — errores comunes y sus fixes
- `docs/API_CONTRACTS.md` — formato del webhook de Evolution API y firmas de funciones PL/pgSQL
- `docs/rollout/PLAN_ROLLOUT.md` — plan de rollout día a día con validaciones y rollback
- `monitoring/queries_debug.sql` — queries de diagnóstico para producción

**Decisiones clave que no deben revertirse:**
- `gpt-4.1` obligatorio para tool calling — mini falla silenciosamente
- Webhook Response inmediato antes de cualquier procesamiento — sin esto hay duplicados
- `fromMe === false` como primera condición — sin esto el bot entra en loop
- `pairedItem: { item: 0 }` en Formatear config — sin esto el workflow explota downstream
- `onError: continueRegularOutput` en todos los Tool nodes de Calendar