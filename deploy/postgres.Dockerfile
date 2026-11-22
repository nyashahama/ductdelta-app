FROM postgres:18-bookworm
ENV POSTGRES_DB=ductdelta \
    POSTGRES_INITDB_ARGS="--auth-local=peer --auth-host=scram-sha-256"
COPY migrations/ /opt/ductdelta/migrations/
COPY --chmod=0755 deploy/migrate.sh /usr/local/bin/ductdelta-migrate
RUN ln -s /usr/local/bin/ductdelta-migrate /docker-entrypoint-initdb.d/10-ductdelta.sh
