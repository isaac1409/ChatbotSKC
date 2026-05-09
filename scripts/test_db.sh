#!/usr/bin/env bash
# Ejecuta el test suite contra la base de datos de STAGING.
# ⚠️  NUNCA ejecutar contra producción.
# Uso: ./scripts/test_db.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$SCRIPT_DIR/../database"

if [ -f "$SCRIPT_DIR/../.env.test" ]; then
  set -a; source "$SCRIPT_DIR/../.env.test"; set +a
elif [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

# Seguridad: verificar que no estamos en producción
DB_NAME="${PGDATABASE:-postgres}"
if [[ "$DB_NAME" == *"prod"* || "$DB_NAME" == "bot_citas" ]]; then
  echo "ERROR: Este script no debe ejecutarse contra la BD de producción ($DB_NAME)"
  echo "       Usa PGDATABASE=bot_citas_test para staging."
  exit 1
fi

echo "==> Ejecutando test suite en: ${PGHOST:-localhost}/${DB_NAME}"
echo ""

psql -f "$DB_DIR/06_test_fixtures.sql" 2>&1 | tee /tmp/test_results.log

echo ""
echo "==> Resultados:"
grep -E "PASÓ|FALLÓ|WARNING|TEST" /tmp/test_results.log || echo "(sin resultados detectados)"

FAILED=$(grep -c "FALLÓ" /tmp/test_results.log || true)
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED test(s) fallaron. Revisar /tmp/test_results.log"
  exit 1
else
  echo "✅ Todos los tests pasaron."
fi
