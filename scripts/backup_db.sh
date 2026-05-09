#!/usr/bin/env bash
# Crea un backup comprimido de la base de datos.
# Uso: ./scripts/backup_db.sh [directorio_destino]
# Destino por defecto: ./backups/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$SCRIPT_DIR/../backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE="$DEST/chatbotskc_${TIMESTAMP}.sql.gz"

if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

mkdir -p "$DEST"

echo "==> Backup iniciado: $FILE"
pg_dump --no-owner --no-acl | gzip > "$FILE"

SIZE=$(du -sh "$FILE" | cut -f1)
echo "✅ Backup completado: $FILE ($SIZE)"

# Rotar backups: mantener solo los 7 más recientes
ls -t "$DEST"/chatbotskc_*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
echo "   Backups anteriores rotados. Retenidos: $(ls "$DEST"/chatbotskc_*.sql.gz 2>/dev/null | wc -l)"
