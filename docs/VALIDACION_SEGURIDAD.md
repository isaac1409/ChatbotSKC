# Validación de Seguridad — Código Generado
> Esta validación responde: ¿el código es seguro para implementar?

---

## RESPUESTA CORTA: SÍ, ES SEGURO — con 3 condiciones

1. Ejecutar los SQL en una base de datos NUEVA (bot-citas-db), no en la existente
2. No modificar evolution-api-db ni la base de datos interna de n8n
3. Mantener el workflow viejo activo como respaldo mientras se prueba el nuevo

---

## COMPATIBILIDAD

| Sistema | Compatible | Detalle |
|---------|-----------|---------|
| evolution-api-db | ✅ | No se toca. Es una BD diferente. |
| n8n postgres (interna) | ✅ | No se toca. Las tablas nuevas van en otra BD. |
| n8n workflows existentes | ✅ | Pueden correr en paralelo. Mismo webhook, idempotencia por `key_id`. |
| Google Calendar API | ✅ | No cambia. Sigue siendo fuente de verdad de citas. |

**El flujo existente NO cambia:**
```
Usuario → WhatsApp → Evolution API → n8n → Google Calendar
```
Lo que se agrega es:
```
n8n → bot-citas-db (copia de citas + usuarios + logs)
```

---

## ANÁLISIS DE TRIGGERS Y FUNCIONES

### ¿Pueden causar deadlocks?
**No.** Los triggers son simples (updated_at, audit log). El trigger de overlap (`fn_validar_overlap_citas`) bloquea a nivel de fila y libera inmediatamente. No hay dependencias circulares.

### ¿Pueden causar race conditions?
**Riesgo menor, mitigado.** La función `upsert_usuario` hace SELECT-luego-INSERT sin lock explícito. Si dos mensajes del mismo usuario llegan exactamente al mismo milisegundo, podría intentar insertar dos veces y el segundo fallaría. **En la práctica esto no ocurre** porque el Redis buffer agrupa mensajes del mismo usuario en una ventana de 5 segundos, procesándolos secuencialmente.

### ¿Pueden causar performance issues?
**No para el volumen esperado.** La función `buscar_slots_disponibles` hace iteraciones, pero para un calendario de una empresa pequeña (< 1000 citas) es instantáneo. Los índices en `02_indexes.sql` cubren los queries más frecuentes.

### ¿Conflictos con otras BDs?
**No.** Las bases de datos PostgreSQL son completamente aisladas entre sí aunque corran en el mismo servidor. bot-citas-db no puede ver ni afectar evolution-api-db ni n8n postgres.

---

## UNA COSA A SABER ANTES DE EJECUTAR

El archivo `01_schema_ddl.sql` crea tipos ENUM (`estado_lead_enum`, etc.) **sin** `IF NOT EXISTS`. Esto significa:
- ✅ Seguro si se ejecuta en una BD **nueva** (bot-citas-db recién creada)
- ❌ Fallaría si se intenta re-ejecutar en la misma BD donde ya existe

**Solución:** bot-citas-db es nueva → no hay problema. Si necesitas re-ejecutar, usa el archivo `05_migration.sql` que está diseñado para ser idempotente.

---

## RESUMEN

| Pregunta | Respuesta |
|----------|-----------|
| ¿El código rompe el workflow actual? | No |
| ¿Afecta evolution-api? | No |
| ¿Afecta la memoria de n8n? | No |
| ¿Google Calendar sigue siendo fuente de verdad? | Sí |
| ¿Puede haber overbooking? | No — trigger previene overlap |
| ¿Puede haber mensajes duplicados? | No — key_id garantiza idempotencia |
| ¿Hay riesgo de perder datos si falla? | No — rollback limpio (ver ROLLBACK.md) |
