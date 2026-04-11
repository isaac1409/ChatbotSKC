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
- **Config dinámica:** Google Sheets (hoja `config`, columnas `campo` / `valor`)
- **Memoria:** Postgres Chat Memory (n8n nativo)
- **Buffer:** Redis
- **Base de datos:** PostgreSQL 15
- **Infraestructura:** Easypanel — todos los servicios están hosteados ahí, sin Docker local

---

## 📁 Estructura del repositorio

```
ChatbotSKC/
├── CLAUDE.md                  ← este archivo
├── docs/
│   └── CLAUDE_CHATBOT_CONTEXT.md   ← contexto completo del stack, bugs y decisiones
└── workflows/
    └── Chatbot_Isaac_vX.json       ← workflow exportado desde n8n (versión actual)
```

**Regla:** cada vez que se estabiliza una versión, exportar el workflow desde
n8n (Settings → Download) y commitear el JSON en `workflows/` con el número de versión.

---

## ✅ Convenciones

- Nombres de archivo de workflows: `Chatbot_[Cliente]_v[N].json`
- Commits en español: `feat:`, `fix:`, `docs:`, `chore:`
- Nunca commitear credenciales ni valores reales de producción
- Un workflow por archivo — no agrupar clientes en un solo JSON

---

## ⚠️ Zonas de NO tocar sin confirmación

- `workflows/*.json` — son exportaciones directas de n8n; editarlos a mano rompe el formato
- `docs/CLAUDE_CHATBOT_CONTEXT.md` — documento maestro; cambios requieren revisión explícita

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

- **Fase:** Producción
- **Workflow activo:** Chatbot_Isaac_v10.json
- **Último avance:** Stack completo funcionando — texto, audio, imagen, Calendar, notificaciones multi-canal
- **Próximos pasos:** Workflow de recordatorio 24h (trigger programado separado), configurar Gmail OAuth2
- **Blockers conocidos:** Gmail OAuth2 pendiente de configurar

> ⚠️ Actualizar esta sección cada vez que se retome el proyecto.

---

## 🧠 Contexto técnico importante

El contexto completo del stack — incluyendo arquitectura, bugs conocidos, reglas del
agente y decisiones de diseño — está en `docs/CLAUDE_CHATBOT_CONTEXT.md`.
Leer ese archivo antes de proponer cualquier cambio al workflow o a la configuración.

**Decisiones clave que no deben revertirse:**
- `gpt-4.1` obligatorio para tool calling — mini falla silenciosamente
- Webhook Response inmediato antes de cualquier procesamiento — sin esto hay duplicados
- `fromMe === false` como primera condición — sin esto el bot entra en loop
- `pairedItem: { item: 0 }` en Formatear config — sin esto el workflow explota downstream
- `onError: continueRegularOutput` en todos los Tool nodes de Calendar