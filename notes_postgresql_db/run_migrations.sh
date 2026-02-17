#!/bin/bash
set -euo pipefail

# Runs SQL migrations in order. Each migration is only applied once, tracked in schema_migrations.
# Uses the same DB settings as startup.sh (db/user/pass/port).
#
# Expected env vars (inherited from startup.sh invocation context):
#   DB_NAME, DB_USER, DB_PASSWORD, DB_PORT, PG_BIN

MIGRATIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migrations"

if [ ! -d "${MIGRATIONS_DIR}" ]; then
  echo "No migrations directory found at ${MIGRATIONS_DIR}. Skipping."
  exit 0
fi

echo "Running database migrations from ${MIGRATIONS_DIR}..."

# Ensure schema_migrations exists before attempting to check versions.
PGPASSWORD="${DB_PASSWORD}" sudo -u postgres ${PG_BIN}/psql \
  -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());"

shopt -s nullglob
for f in "${MIGRATIONS_DIR}"/*.sql; do
  base="$(basename "${f}")"
  version="${base%%_*}"  # "001" from "001_create_notes_tags.sql"

  # If filename doesn't start with digits, use the whole base name (without extension) as version.
  if ! [[ "${version}" =~ ^[0-9]+$ ]]; then
    version="${base%.sql}"
  fi

  applied="$(
    PGPASSWORD="${DB_PASSWORD}" sudo -u postgres ${PG_BIN}/psql \
      -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -tA -c "SELECT 1 FROM schema_migrations WHERE version = '${version}' LIMIT 1;"
  )"

  if [ "${applied}" = "1" ]; then
    echo "✓ Skipping ${base} (version ${version} already applied)"
    continue
  fi

  echo "→ Applying ${base} (version ${version})"
  PGPASSWORD="${DB_PASSWORD}" sudo -u postgres ${PG_BIN}/psql \
    -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -f "${f}"

  # Safety: ensure version is recorded even if the SQL file did not insert it (idempotent upsert).
  PGPASSWORD="${DB_PASSWORD}" sudo -u postgres ${PG_BIN}/psql \
    -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c "INSERT INTO schema_migrations(version) VALUES ('${version}') ON CONFLICT (version) DO NOTHING;"

  echo "✓ Applied ${base}"
done

echo "Migrations complete."
