# Checklist de Cleanup — ChatbotSKC

Ejecutar después de validar que la nueva estructura funciona correctamente en staging.

---

## Fase 1 — Base de datos (Día 1)

- [ ] `./scripts/init_db.sh` — DDL, triggers, funciones, índices
- [ ] Actualizar `config_negocio` con valores reales (sin `REEMPLAZAR_CON_...`)
- [ ] `psql -f database/05_migration.sql` — migrar historial
- [ ] `./scripts/test_db.sh` — test suite en staging pasa (0 FALLÓ)
- [ ] Verificar overlap: `SELECT * FROM monitoring/queries_debug.sql` sección overlap → 0 filas
- [ ] Verificar config: ningún campo contiene `REEMPLAZAR_CON_`

## Fase 2 — n8n Workflows (Día 2, ~30 min downtime)

- [ ] Duplicar workflow actual en n8n como backup (`Chatbot_Isaac_BACKUP_YYYYMMDD`)
- [ ] Exportar workflow actual y commitear en `workflows/`
- [ ] **DOWNTIME START** — Desactivar workflow principal
- [ ] Importar `n8n/Chatbot_Principal_v2.json`
- [ ] Reasignar credenciales en todos los nodos Postgres nuevos:
  - [ ] Verificar idempotencia
  - [ ] Cargar config empresa
  - [ ] Upsert usuario
  - [ ] Sync cita en BD
- [ ] **DOWNTIME END** — Activar `Chatbot_Principal_v2`
- [ ] Enviar mensaje de prueba → verificar respuesta
- [ ] `SELECT * FROM mensajes ORDER BY created_at DESC LIMIT 5;` → debe haber filas
- [ ] Agendar cita de prueba → verificar en `citas` tabla

## Fase 3 — Sub-workflows (Día 3)

- [ ] Importar `n8n/Chatbot_Recordatorio_24h.json`
  - [ ] Reasignar credenciales
  - [ ] Activar workflow
  - [ ] Test manual: verificar query de citas próximas retorna resultados correctos
- [ ] Importar `n8n/Chatbot_Metricas_Nocturnas.json`
  - [ ] Reasignar credenciales
  - [ ] Activar workflow
  - [ ] Test manual: ejecutar manualmente y verificar reporte en WA
- [ ] Importar `n8n/Chatbot_GCal_Sync.json`
  - [ ] Reasignar credenciales (Google Calendar)
  - [ ] Activar workflow
  - [ ] Crear evento en GCal y esperar ≤30 min para ver sync en tabla `citas`

## Fase 4 — Limpieza del repo (Día 4, después de validar todo)

- [ ] `./scripts/cleanup_repo.sh` — eliminar carpetas legacy
  - Elimina: `docs/sql/`, `chatbot_isaac_funcionando_en_prod/`, `Chatbot_Ivan/`
- [ ] Verificar estructura final:
  ```
  database/   n8n/   scripts/   monitoring/   docs/   workflows/
  ```
- [ ] `git add -A && git commit -m "chore: migrar a estructura canónica"`
- [ ] `git push origin CHECK_Workflow_ivan`
- [ ] Abrir PR a `main`

## Fase 5 — Monitoreo post-launch (48h después)

- [ ] `./monitoring/health_check.sh` → todos OK
- [ ] `SELECT * FROM v_errores_pendientes;` → 0 errores
- [ ] Verificar que el recordatorio 24h se ejecutó (revisar logs n8n del día siguiente a las 9 AM)
- [ ] Verificar reporte nocturno en WhatsApp del admin
- [ ] `SELECT * FROM metricas_diarias ORDER BY fecha DESC LIMIT 3;` → datos correctos

---

## Rollback (si algo falla)

### Rollback BD (antes del COMMIT en init_db.sh)
```sql
ROLLBACK;
-- Las tablas nuevas se eliminan. Google Sheets sigue siendo la fuente de config.
```

### Rollback n8n
```
1. n8n → Chatbot_Principal_v2 → Toggle OFF
2. n8n → Chatbot_Isaac_BACKUP_YYYYMMDD → Toggle ON
3. Sistema restaurado en < 2 minutos.
```

### Rollback completo de tablas (solo si necesitas empezar de cero)
```bash
./scripts/cleanup_db.sh --confirm   # solo en staging
```
