# ChatbotSKC

Repositorio de workflows de n8n para chatbots de WhatsApp con IA, desarrollados por el equipo de **Innovasoft Solutions (SKC)**.

Cada workflow es un agente conversacional completo: recibe mensajes de WhatsApp, los procesa con IA, consulta calendarios, gestiona citas y notifica por múltiples canales — todo configurado desde Google Sheets sin tocar el workflow.

---

## Stack

| Capa | Tecnología |
|---|---|
| Orquestación | n8n 1.123.21 (Easypanel) |
| Mensajería | Evolution API v2.3.7 |
| IA principal | OpenAI gpt-4.1 |
| Calendario | Google Calendar (OAuth2) |
| Config dinámica | Google Sheets |
| Memoria conversacional | Postgres Chat Memory |
| Buffer de mensajes | Redis |
| Base de datos | PostgreSQL 15 |
| Infraestructura | Easypanel |

---

## Estructura del repositorio

```
ChatbotSKC/
├── CLAUDE.md                        ← contexto para Claude Code (no modificar)
├── README.md                        ← este archivo
├── docs/
│   └── CLAUDE_CHATBOT_CONTEXT.md    ← referencia técnica completa del stack
└── workflows/
    └── Chatbot_Isaac_v10.json       ← workflow exportado desde n8n
```

### Convención de nombres para workflows

```
Chatbot_[Nombre]_v[N].json
```

Ejemplos:
```
Chatbot_Isaac_v10.json
Chatbot_Ivan_v1.json
Chatbot_Kevin_v1.json
```

---

## Cómo trabajar en este repo

### Ramas

Cada desarrollador trabaja en su propia rama. Los workflows no se mezclan.

| Rama | Responsable |
|---|---|
| `main` | Versiones estables aprobadas |
| `isaac` | Isaac |
| `ivan` | Ivan |
| `kevin` | Kevin |

### Flujo para actualizar un workflow

```bash
# 1. Posicionarte en tu rama
git checkout isaac   # o ivan / kevin

# 2. Exportar el workflow desde n8n
#    n8n → tu workflow → ⋮ → Download
#    Guardar el JSON en workflows/ con el nombre correcto

# 3. Commitear
git add workflows/Chatbot_Isaac_vX.json
git commit -m "feat: descripción del cambio — Chatbot_Isaac vX"
git push origin isaac

# 4. Cuando la versión es estable → Pull Request a main
```

### Reglas

- **Nunca editar los archivos `.json` a mano** — son exportaciones directas de n8n y se corrompen fácilmente.
- **Nunca commitear credenciales** — las variables de entorno se gestionan en Easypanel.
- Un archivo por workflow, un workflow por cliente.
- Siempre incluir el número de versión en el nombre del archivo.

---

## Cómo importar un workflow a n8n

1. Abrir n8n → **Workflows** → botón `+` → **Import from file**
2. Seleccionar el `.json` de la carpeta `workflows/`
3. Configurar las credenciales (ver sección siguiente)
4. Activar el workflow

> ⚠️ Al importar, las credenciales no se transfieren. Hay que reasignarlas manualmente antes de activar.

### Credenciales a configurar tras cada importación

| Credencial | Tipo | Nodos que la usan |
|---|---|---|
| Google Sheets account | OAuth2 | Leer config negocio |
| Google Calendar account | OAuth2 | agendar_cita, cancelar_cita, consultar_citas |
| OpenAI | API Key | AI Agent, Analizar imagen, Transcribir audio |
| Redis | Host / Port | Buffer de mensajes |
| PostgreSQL | Host / DB / User / Pass | Postgres Chat Memory |
| Evolution API | Header Auth (apikey) | HTTP Request — envío de mensajes |

---

## Acceso a servicios (Easypanel)

| Servicio | URL |
|---|---|
| n8n | `https://[n8n.tudominio.com]` |
| Evolution API | `https://[evolution.tudominio.com]` |
| PostgreSQL | interno Easypanel |
| Redis | interno Easypanel |

---

## Documentación técnica

La referencia completa del stack está en [`docs/CLAUDE_CHATBOT_CONTEXT.md`](docs/CLAUDE_CHATBOT_CONTEXT.md):

- Arquitectura del workflow y flujo de datos
- Estructura de configuración en Google Sheets
- Bugs conocidos y sus fixes
- Reglas del AI Agent y system prompt
- Proceso de testing antes de producción
- Historial de versiones

---

## Checklist antes de activar un workflow en producción

```
□ Credenciales reasignadas en todos los nodos
□ Hoja config en Google Sheets completa (nombre_agente, horario_inicio, horario_fin, duracion_reunion, numero_admin, correo_admin, grupo_whatsapp, modo_prueba)
□ modo_prueba = true durante el testing
□ Los 9 casos de prueba pasaron (ver docs/)
□ modo_prueba = false antes de activar en producción
□ JSON del workflow commiteado en el repo antes de activar
```