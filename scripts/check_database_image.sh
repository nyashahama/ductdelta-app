#!/usr/bin/env bash
# Exercise a database image replacement on a synthetic volume with no TCP listener.
set -euo pipefail
image=${1:?pass the locally built DuctDelta PostgreSQL image}
project=$(cd "$(dirname "$0")/.." && pwd)
early=$(mktemp -d)
name="ductdelta-upgrade-${early##*.}"
volume="$name-data"
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null
    rm -rf -- "$early"
}
docker volume create "$volume" >/dev/null
trap cleanup EXIT
cp "$project"/migrations/00{01..17}_*.sql "$early/"
chmod 755 "$early"

start() {
    docker run --detach --name "$name" --network none \
        -v "$volume:/var/lib/postgresql" "$@" \
        -e POSTGRES_PASSWORD=synthetic-test-only \
        -e DUCTDELTA_APP_PASSWORD="$(printf '%064d' 1)" \
        "$image" postgres -c listen_addresses= >/dev/null
    for ((i=0; i<100; i++)); do
        if docker exec "$name" sh -c 'test "$(cat /proc/1/comm)" = postgres && pg_isready -qh /var/run/postgresql'; then
            return
        fi
        sleep 0.25
    done
    echo 'The final database process did not start.' >&2
    return 1
}
sql() { docker exec -u postgres "$name" psql -XqAt -v ON_ERROR_STOP=1 -d ductdelta -c "$1"; }

start -v "$early:/opt/ductdelta/migrations:ro"
[[ "$(sql 'SELECT count(*) FROM ductdelta_deploy.migration')" == 17 ]]
sql "CREATE TABLE public.upgrade_marker(data text); INSERT INTO public.upgrade_marker VALUES ('kept')"
docker stop "$name" >/dev/null
docker rm "$name" >/dev/null
start
expected=$(find "$project/migrations" -name '*.sql' | wc -l)
actual=$(sql "SELECT count(*) FROM ductdelta_deploy.migration")
if [[ "$actual" != "$expected" ]]; then
    echo "Existing volume has $actual migrations after upgrade, expected $expected." >&2
    exit 1
fi
[[ "$(sql 'SELECT data FROM public.upgrade_marker')" == kept ]]
[[ "$(sql "SET ROLE ductdelta_app; SELECT has_function_privilege('ductdelta.web_project_notice_rule(bytea,uuid)','EXECUTE')")" == t ]]
echo 'PASS: replacing the database image applies pending migrations and preserves existing data'
