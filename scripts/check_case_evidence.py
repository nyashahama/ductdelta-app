#!/usr/bin/env python3
"""Check immutable case evidence through the non-owner web login on disposable PostgreSQL."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import uuid

from check_postgres import BIN, PROJECT, ROOT, SECOND_ORGANIZATION_PROJECT, connection, disposable_cluster


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def verify(socket, base_migrations, environment):
    def sql(statement, *, user="dd_web_evidence", error=None):
        response = subprocess.run(
            [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose",
             connection(socket, user)],
            input=statement, text=True, capture_output=True, check=False, timeout=20, env=environment,
        )
        if error:
            assert response.returncode == 3 and f"{error}:" in response.stderr, response.stderr
            return None
        assert response.returncode == 0, response.stderr
        return response.stdout.strip()

    def admin(statement):
        return sql(statement, user="dd_admin")

    for migration in sorted(base_migrations.glob("000[1-5]_*.sql")):
        admin(migration.read_text())
    admin((ROOT / "migrations" / "0006_case_evidence.sql").read_text())
    admin((ROOT / "tests" / "roles.sql").read_text())
    admin((ROOT / "tests" / "fixture.sql").read_text())
    admin("CREATE ROLE dd_web_evidence LOGIN IN ROLE ductdelta_web_runtime")

    def session(actor_suffix):
        key = f"sha256(convert_to('Synthetic evidence key {actor_suffix}', 'UTF8'))"
        digest = f"sha256(convert_to('Synthetic evidence session {actor_suffix}', 'UTF8'))"
        admin(
            "INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at) "
            f"VALUES ('20000000-0000-0000-0000-00000000000{actor_suffix}', "
            f"'Synthetic evidence actor', {key}, statement_timestamp() + interval '1 day')"
        )
        assert sql(f"SELECT ductdelta.web_login({key}, {digest})") == "t"
        return digest

    def grant(actor_suffix, capability):
        admin(
            "INSERT INTO ductdelta.project_workflow_grant "
            "(organization_id, project_id, actor_id, capability) SELECT organization_id, "
            f"project_id, actor_id, '{capability}' FROM ductdelta.project_member "
            f"WHERE project_id = '{PROJECT}' AND actor_id = '20000000-0000-0000-0000-00000000000{actor_suffix}'"
        )

    site = session("1")
    viewer = session("2")
    other_tenant = session("4")
    grant("1", "commercial")
    grant("2", "commercial")

    def create(session_digest, project):
        return json.loads(sql(
            f"SELECT ductdelta.web_create_case({session_digest}, '{project}', '{uuid.uuid4()}', "
            "'Evidence test case', NULL)"
        ))["id"]

    case = create(site, PROJECT)
    foreign_case = create(other_tenant, SECOND_ORGANIZATION_PROJECT)
    body = "convert_to('Synthetic source with exact bytes', 'UTF8')"
    operation = uuid.uuid4()

    def attach(*, user=site, project=PROJECT, case_id=case, op=operation, filename="record.txt",
               media_type="text/plain", content=body, caption="Source note", access="site", error=None):
        raw = sql(
            f"SELECT ductdelta.web_attach_case_file({user}, '{project}', '{case_id}', '{op}', "
            f"{literal(filename)}, {literal(media_type)}, {content}, "
            f"{literal(caption) if caption is not None else 'NULL'}, {literal(access)})",
            error=error,
        )
        return json.loads(raw) if raw is not None else None

    def files(*, user=site, project=PROJECT, case_id=case, error=None):
        raw = sql(f"SELECT ductdelta.web_case_files({user}, '{project}', '{case_id}')", error=error)
        return json.loads(raw) if raw is not None else None

    def download(file_id, *, user=site, project=PROJECT, case_id=case, error=None):
        return sql(
            "SELECT filename, media_type, encode(content, 'hex') FROM "
            f"ductdelta.web_case_file({user}, '{project}', '{case_id}', '{file_id}')",
            error=error,
        )

    assert files() == []
    attached = attach()
    assert attach() == attached
    assert attached["filename"] == "record.txt"
    assert attached["media_type"] == "text/plain"
    assert attached["byte_size"] == len("Synthetic source with exact bytes")
    assert attached["sha256"] == admin(f"SELECT encode(sha256({body}), 'hex')")
    assert attached["caption"] == "Source note"
    assert attached["access_class"] == "site"
    assert files(user=viewer) == [attached]
    assert download(attached["id"], user=viewer) == (
        "record.txt|text/plain|" + b"Synthetic source with exact bytes".hex()
    )
    attach(caption="Different caption", error="DD001")
    attach(content="convert_to('Changed', 'UTF8')", error="DD001")
    attach(user=viewer, error="42501")
    attach(user=other_tenant, op=uuid.uuid4(), error="42501")
    attach(case_id=foreign_case, op=uuid.uuid4(), error="42501")
    files(case_id=foreign_case, error="42501")
    download(attached["id"], user=other_tenant, error="42501")
    download(attached["id"], user=other_tenant, project=SECOND_ORGANIZATION_PROJECT,
             case_id=foreign_case, error="42501")
    download(uuid.uuid4(), error="42501")
    sql("SELECT content FROM ductdelta.case_file", error="42501")
    sql("UPDATE ductdelta.case_file SET caption = 'tampered'", error="42501")
    sql("SELECT * FROM ductdelta.case_file_metadata", error="42501")

    concurrent_op = uuid.uuid4()
    with ThreadPoolExecutor(max_workers=2) as executor:
        retries = [executor.submit(attach, op=concurrent_op) for _ in range(2)]
    concurrent_attachment = retries[0].result()
    assert retries[1].result() == concurrent_attachment
    assert {file["id"] for file in files()} == {attached["id"], concurrent_attachment["id"]}

    attach(op=uuid.uuid4(), access="finance", error="42501")
    grant("1", "finance")
    bank = attach(op=uuid.uuid4(), access="finance", caption=None)
    assert bank["caption"] is None
    assert len(files()) == 3
    assert {file["id"] for file in files(user=viewer)} == {attached["id"], concurrent_attachment["id"]}
    download(bank["id"], user=viewer, error="42501")
    grant("2", "finance")
    assert len(files(user=viewer)) == 3
    assert download(bank["id"], user=viewer).startswith("record.txt|text/plain|")
    attach(user=viewer, access="finance", op=uuid.uuid4(), error="42501")
    admin("DELETE FROM ductdelta.project_workflow_grant WHERE capability = 'finance' "
          f"AND project_id = '{PROJECT}' AND actor_id = '20000000-0000-0000-0000-000000000002'")
    download(bank["id"], user=viewer, error="42501")

    attach(op=uuid.uuid4(), filename="../record.txt", error="22023")
    attach(op=uuid.uuid4(), filename="record\n.txt", error="22023")
    attach(op=uuid.uuid4(), media_type="image/png", error="22023")
    attach(op=uuid.uuid4(), media_type="text/html", error="22023")
    attach(op=uuid.uuid4(), media_type="application/pdf",
           content="decode('255044462d312e370a2525454f460a', 'hex')")
    attach(op=uuid.uuid4(), media_type="image/png",
           content="decode('89504e470d0a1a0a0000000049454e44ae426082', 'hex')")
    attach(op=uuid.uuid4(), media_type="image/jpeg", content="decode('ffd8ffe00002ffd9', 'hex')")
    attach(op=uuid.uuid4(), content="decode('ff', 'hex')", error="22023")
    attach(op=uuid.uuid4(), content="decode('31ff', 'hex')", error="22023")
    attach(op=uuid.uuid4(), content="decode('310133', 'hex')", error="22023")
    attach(op=uuid.uuid4(), content="convert_to('', 'UTF8')", error="22023")
    attach(op=uuid.uuid4(), content="convert_to(repeat('x', 5242881), 'UTF8')", error="22023")
    boundary = attach(op=uuid.uuid4(), content="convert_to(repeat('x', 5242880), 'UTF8')")
    assert boundary["byte_size"] == 5 * 1024 * 1024

    assert json.loads(sql(
        f"SELECT ductdelta.web_case_action({site}, '{PROJECT}', '{case}', '{uuid.uuid4()}', "
        """'close', '{"reason":"Inspection only","outcome":"no_change"}'::jsonb)"""
    ))["id"]
    assert attach() == attached
    attach(op=uuid.uuid4(), error="23514")
    assert download(attached["id"]).startswith("record.txt|text/plain|")
    print("PASS: original bytes, content limits, idempotency, case scope, finance access and closed-case replay")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-migrations", type=Path, default=ROOT / "migrations")
    options = parser.parse_args()
    (ROOT / "target").mkdir(exist_ok=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    with disposable_cluster(environment) as socket:
        verify(socket, options.base_migrations, environment)
