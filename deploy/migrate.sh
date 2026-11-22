#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export PGHOST=${PGHOST:-/var/run/postgresql}
directory=${1:-/opt/ductdelta/migrations}
if [[ "$PGHOST" != /* ]]; then
    echo 'Run deployment migrations over the local PostgreSQL socket.' >&2
    exit 1
fi
if [[ ! "${DUCTDELTA_APP_PASSWORD:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo 'Set DUCTDELTA_APP_PASSWORD to a randomly generated 64-digit hex value.' >&2
    exit 1
fi

shopt -s nullglob
migrations=("$directory"/*.sql)
if (( ${#migrations[@]} == 0 )); then
    echo 'No deployment migrations found.' >&2
    exit 1
fi
for file in "${migrations[@]}"; do
    if [[ ! "${file##*/}" =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ||
        "$(head -n1 "$file")" != 'BEGIN;' || "$(tail -n1 "$file")" != 'COMMIT;' ]]; then
        echo "Invalid migration filename or transaction boundaries: ${file##*/}" >&2
        exit 1
    fi
done

{
    cat <<'SQL'
SELECT pg_advisory_lock(414558174523124242);
CREATE SCHEMA IF NOT EXISTS ductdelta_deploy;
REVOKE ALL ON SCHEMA ductdelta_deploy FROM PUBLIC;
CREATE TABLE IF NOT EXISTS ductdelta_deploy.migration (
    filename text PRIMARY KEY,
    checksum text NOT NULL
);
SQL
    for file in "${migrations[@]}"; do
        name=${file##*/}
        checksum=$(sha256sum < "$file")
        checksum=${checksum%% *}
        printf "\\set filename %s\n\\set checksum %s\n" "$name" "$checksum"
        cat <<'SQL'
SELECT NOT EXISTS (SELECT FROM ductdelta_deploy.migration WHERE filename = :'filename') AS pending,
    EXISTS (SELECT FROM ductdelta_deploy.migration
            WHERE filename = :'filename' AND checksum <> :'checksum') AS changed
\gset
\if :changed
DO $$ BEGIN RAISE EXCEPTION 'An applied deployment migration was edited'; END $$;
\endif
\if :pending
SQL
        printf '\\echo Applying %s\n' "$name"
        sed '$d' "$file"
        cat <<'SQL'
RESET ROLE;
INSERT INTO ductdelta_deploy.migration VALUES (:'filename', :'checksum');
COMMIT;
\endif
SQL
    done
    cat <<'SQL'
SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ductdelta_app') AS new_role
\gset
\if :new_role
\getenv app_password DUCTDELTA_APP_PASSWORD
CREATE ROLE ductdelta_app LOGIN PASSWORD :'app_password' IN ROLE ductdelta_web_runtime;
\endif
SQL
} | psql -X --no-password --quiet --set ON_ERROR_STOP=1 \
    --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-ductdelta}"
