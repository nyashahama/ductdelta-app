#!/usr/bin/env python3
"""Check deployment migrations with a disposable socket-only PostgreSQL cluster."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from check_postgres import BIN, PORT, ROOT, connection, disposable_cluster


def verify(socket, environment):
    def sql(statement, actor="dd_admin", *, expected=0):
        result = subprocess.run(
            [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", connection(socket, actor)],
            input=statement, env=environment, text=True, capture_output=True, timeout=10,
        )
        assert result.returncode == expected, result.stderr
        return result.stdout.strip()

    def migrate(directory, *, expected=0):
        result = subprocess.run(
            ["bash", ROOT / "deploy/migrate.sh", directory],
            env={
                **environment,
                "PATH": f"{BIN}:{environment['PATH']}",
                "PGHOST": str(socket),
                "PGPORT": PORT,
                "POSTGRES_USER": "dd_admin",
                "POSTGRES_DB": "postgres",
                "DUCTDELTA_APP_PASSWORD": "a" * 64,
            },
            text=True, capture_output=True, timeout=25,
        )
        assert result.returncode == expected, (result.stdout, result.stderr)
        return result

    source = ROOT / "migrations"
    expected_count = str(len(list(source.glob("*.sql"))))
    migrate(source)
    migrate(source)
    assert sql("SELECT count(*) FROM ductdelta_deploy.migration") == expected_count
    assert sql("""
        SELECT NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolbypassrls
            AND pg_has_role(rolname, 'ductdelta_web_runtime', 'USAGE')
        FROM pg_roles WHERE rolname = current_user
        """, "ductdelta_app") == "t"
    sql("SELECT * FROM ductdelta.observation", "ductdelta_app", expected=3)
    sql("SELECT * FROM ductdelta_deploy.migration", "ductdelta_app", expected=3)

    with tempfile.TemporaryDirectory() as directory:
        migrations = Path(directory) / "migrations"
        shutil.copytree(source, migrations)
        future = migrations / "9999_test.sql"
        future.write_text("BEGIN;\nCREATE TABLE public.migration_test(id int);\nSELECT 1/0;\nCOMMIT;\n")
        migrate(migrations, expected=3)
        assert sql("SELECT to_regclass('public.migration_test') IS NULL") == "t"
        assert sql("SELECT count(*) FROM ductdelta_deploy.migration") == expected_count
        future.write_text("BEGIN;\nCREATE TABLE public.migration_test(id int);\nCOMMIT;\n")
        migrate(migrations)
        assert sql("SELECT to_regclass('public.migration_test') IS NOT NULL") == "t"
        future.write_text("BEGIN;\nSELECT 1;\nCOMMIT;\n")
        migrate(migrations, expected=3)
        assert sql("SELECT count(*) FROM ductdelta_deploy.migration") == str(int(expected_count) + 1)
    print("PASS: deployment migrations retry, roll back failures, detect edits and provision a restricted app role")


if __name__ == "__main__":
    (ROOT / "target").mkdir(exist_ok=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    with disposable_cluster(environment) as socket:
        verify(socket, environment)
