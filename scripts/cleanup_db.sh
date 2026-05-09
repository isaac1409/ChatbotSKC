#!/usr/bin/env bash
# Elimina TODAS las tablas del schema ChatbotSKC.
# ⚠️  DESTRUCTOR — Solo para development/staging. NUNCA en producción.
# Uso: ./scripts/cleanup_db.sh --confirm

set -euo pipefail

if [[ "${1:-}" != "--confirm" ]]; then
  echo "DANGER: Este script elimina todas las tablas de ChatbotSKC."
  echo "        Ejecuta con --confirm para confirmar."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

DB_NAME="${PGDATABASE:-postgres}"
if [[ "$DB_NAME" == *"prod"* || "$DB_NAME" == "bot_citas" ]]; then
  echo "ERROR: Rechazado. No se puede ejecutar cleanup en producción ($DB_NAME)."
  exit 1
fi

echo "==> Eliminando objetos del schema ChatbotSKC en $DB_NAME..."

psql <<'SQL'
DROP TABLE IF EXISTS metricas_diarias CASCADE;
DROP TABLE IF EXISTS error_log CASCADE;
DROP TABLE IF EXISTS audit_log CASCADE;
DROP TABLE IF EXISTS citas CASCADE;
DROP TABLE IF EXISTS mensajes CASCADE;
DROP TABLE IF EXISTS sesiones CASCADE;
DROP TABLE IF EXISTS usuarios CASCADE;
DROP TABLE IF EXISTS config_negocio CASCADE;
DROP TABLE IF EXISTS instancias_whatsapp CASCADE;
DROP TABLE IF EXISTS empresas CASCADE;
DROP TYPE IF EXISTS estado_lead_enum CASCADE;
DROP TYPE IF EXISTS estado_sesion_enum CASCADE;
DROP TYPE IF EXISTS estado_cita_enum CASCADE;
DROP TYPE IF EXISTS canal_cita_enum CASCADE;
DROP TYPE IF EXISTS direccion_mensaje_enum CASCADE;
DROP TYPE IF EXISTS tipo_mensaje_enum CASCADE;
SQL

echo "✅ Cleanup completado en $DB_NAME."
