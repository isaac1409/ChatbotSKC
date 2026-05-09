#!/usr/bin/env bash
# Inicializa la base de datos desde cero.
# Uso: ./scripts/init_db.sh
# Requiere: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE en el entorno o .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$SCRIPT_DIR/../database"

# Cargar .env si existe
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a
  source "$SCRIPT_DIR/../.env"
  set +a
fi

echo "==> Conectando a ${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-postgres}"
psql -c "SELECT version();" || { echo "ERROR: No se pudo conectar a PostgreSQL"; exit 1; }

echo "==> [1/4] Ejecutando DDL..."
psql -f "$DB_DIR/01_schema_ddl.sql" 2>&1 | tee /tmp/init_ddl.log
grep -i "error" /tmp/init_ddl.log && echo "ADVERTENCIA: Revisa el log arriba" || echo "DDL OK"

echo "==> [2/4] Creando triggers..."
psql -f "$DB_DIR/03_triggers.sql" 2>&1 | tee /tmp/init_triggers.log
echo "Triggers OK"

echo "==> [3/4] Creando funciones y vistas..."
psql -f "$DB_DIR/04_functions.sql" 2>&1 | tee /tmp/init_functions.log
echo "Funciones OK"

echo "==> [4/4] Creando índices (CONCURRENTLY — puede tardar)..."
psql -f "$DB_DIR/02_indexes.sql" 2>&1 | tee /tmp/init_indexes.log
echo "Índices OK"

echo ""
echo "==> Validación final:"
psql -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('empresas','usuarios','citas','sesiones','mensajes','config_negocio') ORDER BY table_name;"

echo ""
echo "✅ Base de datos inicializada correctamente."
echo "   Siguiente paso: Ejecutar scripts/migrate_data.sh para migrar historial existente."
