#!/usr/bin/env bash
set -Eeo pipefail

source /usr/local/bin/docker-entrypoint.sh
if [[ ${1:0:1} == - ]]; then
    set -- postgres "$@"
fi

# The upstream init hook handles fresh volumes. Upgrade existing volumes before
# the final server accepts network clients.
if [[ ${1:-} == postgres && -s "$PGDATA/PG_VERSION" ]] && ! _pg_want_help "$@"; then
    docker_setup_env
    if (( EUID == 0 )); then
        docker_create_db_directories
        exec gosu postgres "$0" "$@"
    fi
    docker_temp_server_start "$@"
    trap docker_temp_server_stop EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    /usr/local/bin/ductdelta-migrate
    docker_temp_server_stop
    trap - EXIT TERM INT
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
