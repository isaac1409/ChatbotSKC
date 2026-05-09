#!/usr/bin/env bash
# Health check rápido del sistema ChatbotSKC.
# Uso: ./monitoring/health_check.sh
# Salida: OK / WARNING / ERROR por componente.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

PASS=0
WARN=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  local expected="${3:-}"

  if result=$(eval "$cmd" 2>&1); then
    if [ -n "$expected" ] && ! echo "$result" | grep -q "$expected"; then
      echo "  WARN  $label: esperado '$expected', obtenido: $result"
      ((WARN++))
    else
      echo "  OK    $label"
      ((PASS++))
    fi
  else
    echo "  FAIL  $label: $result"
    ((FAIL++))
  fi
}

echo "═══════════════════════════════════════"
echo " ChatbotSKC Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════"

echo ""
echo "── PostgreSQL ──────────────────────────"
check "Conectividad" "psql -c 'SELECT 1' -t" "1"
check "Tabla empresas" "psql -c 'SELECT COUNT(*) FROM empresas' -t"
check "Tabla citas" "psql -c 'SELECT COUNT(*) FROM citas' -t"
check "Tabla usuarios" "psql -c 'SELECT COUNT(*) FROM usuarios' -t"
check "Extensión pgcrypto" "psql -c \"SELECT extname FROM pg_extension WHERE extname='pgcrypto'\" -t" "pgcrypto"
check "Extensión btree_gist" "psql -c \"SELECT extname FROM pg_extension WHERE extname='btree_gist'\" -t" "btree_gist"
check "Sin errores pendientes" "psql -c 'SELECT COUNT(*) FROM error_log WHERE resuelto=false' -t"
check "Sin duplicados key_id" "psql -c 'SELECT COUNT(*) FROM (SELECT key_id FROM mensajes GROUP BY key_id HAVING COUNT(*)>1) x' -t" "0"

echo ""
echo "── n8n ─────────────────────────────────"
N8N_URL="${N8N_URL:-http://localhost:5678}"
check "n8n accesible" "curl -sf ${N8N_URL}/healthz"

echo ""
echo "── Evolution API ───────────────────────"
EVOLUTION_HOST="${EVOLUTION_HOST:-http://localhost:8080}"
EVOLUTION_API_KEY="${EVOLUTION_API_KEY:-}"
check "Evolution API accesible" "curl -sf -H 'apikey: ${EVOLUTION_API_KEY}' ${EVOLUTION_HOST}/instance/fetchInstances"

echo ""
echo "═══════════════════════════════════════"
echo " Resultados: $PASS OK  |  $WARN WARN  |  $FAIL FAIL"
echo "═══════════════════════════════════════"

[ "$FAIL" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 2
exit 0
