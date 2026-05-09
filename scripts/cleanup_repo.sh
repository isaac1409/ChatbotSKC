#!/usr/bin/env bash
# Limpia la estructura legacy del repositorio.
# Ejecutar UNA SOLA VEZ después de validar que la nueva estructura funciona.
# Uso: ./scripts/cleanup_repo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

echo "==> Validando que database/ tiene todos los SQL..."
required=(01_schema_ddl.sql 02_indexes.sql 03_triggers.sql 04_functions.sql 05_migration.sql 06_test_fixtures.sql)
for f in "${required[@]}"; do
  [ -f "$ROOT/database/$f" ] || { echo "ERROR: Falta $ROOT/database/$f"; exit 1; }
done
echo "   OK — todos los archivos SQL están en database/"

echo ""
echo "==> Archivos legacy a eliminar:"
echo "   docs/sql/  (movidos a database/)"
echo "   chatbot_isaac_funcionando_en_prod/  (producción → n8n/)"
echo "   Chatbot_Ivan/  (legacy, no mantenido)"

read -p "¿Confirmar eliminación? [y/N] " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 0; }

rm -rf "$ROOT/docs/sql"
echo "   ✓ docs/sql/ eliminado"

rm -rf "$ROOT/chatbot_isaac_funcionando_en_prod"
echo "   ✓ chatbot_isaac_funcionando_en_prod/ eliminado"

rm -rf "$ROOT/Chatbot_Ivan"
echo "   ✓ Chatbot_Ivan/ eliminado"

echo ""
echo "✅ Limpieza completada. Estructura canónica activa."
echo "   Recuerda: git add -A && git commit -m 'chore: migrar a estructura canónica'"
