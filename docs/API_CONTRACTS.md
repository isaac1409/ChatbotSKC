# API Contracts — ChatbotSKC

Especificaciones de las interfaces entre componentes del sistema.

---

## Evolution API → n8n (Webhook entrante)

### Endpoint
```
POST /webhook/aa0cdd49-6d3b-4a28-a690-7be70d4ffe70
```

### Payload (mensaje de texto)
```json
{
  "event": "messages.upsert",
  "instance": "SKC",
  "data": {
    "key": {
      "remoteJid": "5214921000001@s.whatsapp.net",
      "fromMe": false,
      "id": "3EB0UNIQUE_MESSAGE_ID"
    },
    "pushName": "Nombre del contacto",
    "message": {
      "conversation": "Hola, quiero agendar una cita"
    },
    "messageType": "conversation",
    "messageTimestamp": 1715174400
  }
}
```

### Payload (mensaje de audio)
```json
{
  "data": {
    "key": { "remoteJid": "...", "fromMe": false, "id": "..." },
    "message": {
      "audioMessage": {
        "url": "https://mmg.whatsapp.net/...",
        "mimetype": "audio/ogg; codecs=opus",
        "fileLength": "12345",
        "seconds": 8
      }
    },
    "messageType": "audioMessage"
  }
}
```

### Payload (mensaje de imagen)
```json
{
  "data": {
    "key": { "remoteJid": "...", "fromMe": false, "id": "..." },
    "message": {
      "imageMessage": {
        "url": "https://mmg.whatsapp.net/...",
        "caption": "texto opcional",
        "mimetype": "image/jpeg"
      }
    },
    "messageType": "imageMessage"
  }
}
```

### Campos usados por el workflow

| Campo n8n | Fuente | Uso |
|---|---|---|
| `$json.body.instance` | `instance` | Lookup empresa_id en instancias_whatsapp |
| `$json.body.data.key.id` | `data.key.id` | Idempotencia (key_id UNIQUE en mensajes) |
| `$json.body.data.key.fromMe` | `data.key.fromMe` | Anti-loop (filtrar mensajes propios) |
| `$json.body.data.key.remoteJid` | `data.key.remoteJid` | numero_whatsapp del usuario |
| `$json.body.data.pushName` | `data.pushName` | Nombre para upsert_usuario |
| `$json.body.data.message.conversation` | | Texto del mensaje |

---

## n8n → Evolution API (Envío de mensajes)

### Enviar texto
```
POST https://{EVOLUTION_HOST}/message/sendText/{instance}
Headers: apikey: {EVOLUTION_API_KEY}

Body:
{
  "number": "5214921000001",
  "text": "Respuesta del chatbot"
}
```

### Enviar con delay (anti-spam)
```json
{
  "number": "5214921000001",
  "text": "Mensaje",
  "delay": 1200
}
```

---

## PostgreSQL — Funciones públicas

### `upsert_usuario(empresa_id, numero_wa, nombre, email, empresa_nombre, servicio, notas) → JSONB`
```json
{
  "id": "uuid",
  "numero_limpio": "5214921000001",
  "es_nuevo": true,
  "baneado": false
}
```

### `validar_puede_agendar(empresa_id, usuario_id) → JSONB`
```json
{
  "puede": true,
  "razon": null
}
// o
{
  "puede": false,
  "razon": "usuario_baneado"         // o "limite_citas_activas"
}
```

### `buscar_slots_disponibles(empresa_id, desde, hasta, duracion_min, hora_inicio, hora_fin, max_resultados) → SETOF RECORD`
```
(slot_inicio timestamptz, slot_fin timestamptz)
```

### `registrar_cita(empresa_id, usuario_id, google_event_id, google_calendar_id, titulo, inicio, fin, descripcion) → UUID`
Retorna el `id` de la cita creada o actualizada (ON CONFLICT DO UPDATE).

### `cancelar_cita_bd(google_event_id, motivo) → BOOLEAN`
Retorna `true` si encontró y canceló la cita, `false` si no existía.

### `reprogramar_cita(google_event_id, nuevo_inicio, nuevo_fin) → BOOLEAN`

### `get_config_empresa(empresa_id) → JSONB`
```json
{
  "nombre_empresa": "ZURA Solutions",
  "numero_admin": "+521XXXXXXXXXX",
  "correo_admin": "admin@empresa.com",
  "grupo_whatsapp": "GRUPO_ID@g.us",
  "horario_inicio": "10:00:00",
  "horario_fin": "17:00:00",
  "duracion_reunion": "30",
  "nombre_agente": "Zura",
  "modo_prueba": "false"
}
```

### `calcular_metricas_diarias(empresa_id, fecha) → VOID`
Inserta o actualiza la fila en `metricas_diarias` para la fecha indicada.

---

## PostgreSQL — Vistas

### `v_proximas_citas`
```sql
SELECT cita_id, titulo, inicio, fin, estado, recordatorio_enviado,
       nombre_usuario, numero_whatsapp, empresa_id
FROM v_proximas_citas;
```

### `v_dashboard_leads`
```sql
SELECT estado_lead, COUNT(*), empresa_id
FROM v_dashboard_leads GROUP BY estado_lead, empresa_id;
```

### `v_errores_pendientes`
```sql
SELECT id, empresa_id, origen, error_code, mensaje, created_at
FROM v_errores_pendientes ORDER BY created_at DESC;
```

---

## Códigos de error (tabla `error_log`)

| `error_code` | Origen | Descripción |
|---|---|---|
| `WA_SEND_FAILED` | recordatorio_24h | Fallo al enviar WA de recordatorio |
| `REPORT_SEND_FAILED` | metricas_nocturnas | Fallo al enviar reporte nocturno |
| `SYNC_ERROR` | gcal_sync | Error sincronizando evento de GCal a BD |
| `CALENDAR_ERROR` | chatbot_principal | Error en tool de Google Calendar |
| `AI_ERROR` | chatbot_principal | Error en llamada a OpenAI |
| `DB_ERROR` | cualquier origen | Error genérico de BD |

---

## ENUMs de la base de datos

```sql
TYPE estado_lead_enum   AS ENUM ('nuevo','contactado','calificado','convertido','perdido')
TYPE estado_sesion_enum AS ENUM ('activa','completada','abandonada','error')
TYPE estado_cita_enum   AS ENUM ('pendiente','confirmada','completada','cancelada','no_show')
TYPE canal_cita_enum    AS ENUM ('whatsapp','web','telefono','referido')
TYPE direccion_mensaje_enum AS ENUM ('entrada','salida')
TYPE tipo_mensaje_enum  AS ENUM ('texto','audio','imagen','video','documento','sticker')
```
