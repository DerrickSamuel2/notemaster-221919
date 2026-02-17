#!/bin/bash
set -euo pipefail

# Runs SQL migrations in order. Each migration is only applied once, tracked in schema_migrations.
#
# This script is intended to be:
#  - Called from startup.sh (which typically sets DB_* and PG_BIN), AND
#  - Called manually by an operator.
#
# It therefore provides sensible defaults and/or clear errors when required
# configuration is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"

# Allow manual usage without requiring callers to export everything.
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5000}"

# PG_BIN is optional; discover a usable default if missing.
if [ -z "${PG_BIN:-}" ]; then
  PG_VERSION="$(ls /usr/lib/postgresql/ 2>/dev/null | head -1 || true)"
  if [ -n "${PG_VERSION}" ] && [ -d "/usr/lib/postgresql/${PG_VERSION}/bin" ]; then
    PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
  else
    PG_BIN=""
  fi
fi

# Validate we have required executables.
if [ -z "${PG_BIN}" ] || [ ! -x "${PG_BIN}/psql" ]; then
  echo "✗ PG_BIN is not set or invalid, and psql could not be found automatically."
  echo "  Please export PG_BIN to your postgres bin directory, e.g.:"
  echo "    export PG_BIN=/usr/lib/postgresql/<version>/bin"
  echo "  Current PG_BIN='${PG_BIN:-}'"
  exit 1
fi

if [ ! -d "${MIGRATIONS_DIR}" ]; then
  echo "No migrations directory found at ${MIGRATIONS_DIR}. Skipping."
  exit 0
fi

echo "Running database migrations from ${MIGRATIONS_DIR}..."
echo "Using:"
echo "  DB_NAME=${DB_NAME}"
echo "  DB_USER=${DB_USER}"
echo "  DB_PORT=${DB_PORT}"
echo "  PG_BIN=${PG_BIN}"

# Helpful early connectivity check (clear error if DB isn't reachable).
if ! sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1; then
  echo "✗ PostgreSQL is not ready on port ${DB_PORT}."
  echo "  Start Postgres (or run ./startup.sh) and retry."
  exit 1
fi

# Ensure schema_migrations exists before attempting to check versions.
PGPASSWORD="${DB_PASSWORD}" sudo -u postgres "${PG_BIN}/psql" \
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
    PGPASSWORD="${DB_PASSWORD}" sudo -u postgres "${PG_BIN}/psql" \
      -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -tA -c "SELECT 1 FROM schema_migrations WHERE version = '${version}' LIMIT 1;"
  )"

  if [ "${applied}" = "1" ]; then
    echo "✓ Skipping ${base} (version ${version} already applied)"
    continue
  fi

  echo "→ Applying ${base} (version ${version})"
  PGPASSWORD="${DB_PASSWORD}" sudo -u postgres "${PG_BIN}/psql" \
    -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -f "${f}"

  # Safety: ensure version is recorded even if the SQL file did not insert it (idempotent upsert).
  PGPASSWORD="${DB_PASSWORD}" sudo -u postgres "${PG_BIN}/psql" \
    -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c "INSERT INTO schema_migrations(version) VALUES ('${version}') ON CONFLICT (version) DO NOTHING;"

  echo "✓ Applied ${base}"
done

echo "Migrations complete."
