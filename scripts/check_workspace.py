#!/usr/bin/env python3
"""Verify the signed-in workspace over HTTP using a disposable PostgreSQL cluster."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

from check_postgres import BIN, CLI, PROJECT, REPORTER, ROOT, SECOND_ORGANIZATION_PROJECT
from check_postgres import connection, disposable_cluster

VIEWER = "20000000-0000-0000-0000-000000000002"
OTHER_ORGANIZATION = "20000000-0000-0000-0000-000000000004"
APPLICATION_NAME = "ductdelta_workspace_check"


class Workspace:
    def __init__(self, database_socket, port, environment):
        self.database_socket = database_socket
        self.port = port
        self.origin = f"http://127.0.0.1:{port}"
        self.environment = environment

    def sql(self, sql, actor="dd_admin"):
        return subprocess.run(
            [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", connection(self.database_socket, actor)],
            input=sql, text=True, capture_output=True, check=True, env=self.environment, timeout=10,
        ).stdout.strip()

    def key(self, actor, name):
        return subprocess.run(
            [CLI, "issue-key", actor, name],
            env={**self.environment, "DUCTDELTA_DATABASE_URL": connection(self.database_socket, "dd_admin")},
            capture_output=True, text=True, check=True, timeout=10,
        ).stdout.strip()

    def request(self, path, method="GET", data=None, cookie=None, *, expected=200, origin=None):
        headers = {"Origin": origin or self.origin}
        if cookie:
            headers["Cookie"] = cookie
        if data is not None:
            headers["Content-Type"] = "application/json"
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            client.request(method, path, body=None if data is None else json.dumps(data), headers=headers)
            response = client.getresponse()
            payload = response.read()
            assert response.status == expected, (method, path, response.status, payload)
            if "application/json" in response.getheader("Content-Type", ""):
                payload = json.loads(payload)
            return payload, response.headers
        finally:
            client.close()

    def sign_in(self, key):
        _, headers = self.request("/api/session", "POST", {"key": key}, expected=204)
        cookie = headers["Set-Cookie"]
        assert "HttpOnly" in cookie and "SameSite=Strict" in cookie
        return cookie.split(";", 1)[0]


@contextmanager
def workspace(
    port=None, *, backup=None, frontend=None, seed=True, seed_before=None, before_migration=None,
    service_env=None, service_stderr=None,
):
    target = ROOT / "target"
    subprocess.run(["cargo", "build", "--locked", "--target-dir", target], cwd=ROOT, check=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith(("PG", "DUCTDELTA_"))}
    with disposable_cluster(environment) as database_socket:
        if port is None:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
        server = Workspace(database_socket, port, environment)
        if backup is None:
            for migration in sorted((ROOT / "migrations").glob("*.sql")):
                if seed and migration.name == seed_before:
                    server.sql((ROOT / "tests/fixture.sql").read_text())
                if before_migration and migration.name == before_migration[0]:
                    before_migration[1](server)
                server.sql(migration.read_text())
            if seed and seed_before is None:
                server.sql((ROOT / "tests/fixture.sql").read_text())
        else:
            server.sql(
                "CREATE ROLE ductdelta_owner NOLOGIN;"
                "CREATE ROLE ductdelta_runtime NOLOGIN;"
                "CREATE ROLE ductdelta_web_runtime NOLOGIN;"
            )
        server.sql((ROOT / "tests/roles.sql").read_text())
        server.sql("CREATE ROLE dd_web LOGIN IN ROLE ductdelta_web_runtime;")
        if backup is not None:
            subprocess.run(
                [BIN / "pg_restore", "--exit-on-error", "--dbname",
                 connection(database_socket, "dd_admin"), backup],
                env=environment, check=True, timeout=25,
            )
        with subprocess.Popen(
            [CLI, "serve"], cwd=ROOT, stderr=service_stderr, env={
                **environment,
                **(service_env or {}),
                "DUCTDELTA_DATABASE_URL": (
                    f'{connection(database_socket, "dd_web")} application_name={APPLICATION_NAME}'
                ),
                "DUCTDELTA_LISTEN": f"127.0.0.1:{port}",
                **({"DUCTDELTA_WEB_DIST": str(frontend)} if frontend is not None else {}),
            },
        ) as process:
            try:
                for _ in range(100):
                    assert process.poll() is None, "Workspace stopped before accepting requests."
                    try:
                        server.request("/healthz", expected=204)
                        break
                    except ConnectionError:
                        time.sleep(0.03)
                else:
                    raise AssertionError("Workspace did not accept HTTP connections.")
                yield server
            finally:
                process.terminate()
                process.wait(timeout=10)


def grant_demo_capabilities(server):
    server.sql(
        "INSERT INTO ductdelta.project_workflow_grant "
        "(organization_id, project_id, actor_id, capability) "
        "SELECT organization_id, project_id, actor_id, grants.capability "
        "FROM ductdelta.project_member CROSS JOIN "
        "(VALUES ('direction'), ('commercial'), ('finance')) AS grants(capability) "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}'"
    )


def verify(server):
    path = f"/api/projects/{PROJECT}/observations"
    _, headers = server.request("/healthz", expected=204)
    assert "frame-ancestors" in headers["Content-Security-Policy"]
    server.request("/api/session", expected=401)
    reporter_key = server.key(REPORTER, "Site reporter")
    server.request("/api/session", "POST", {"key": reporter_key}, origin="https://invalid.example", expected=403)
    server.request("/api/session", "POST", {"key": "0" * 64}, expected=401)
    reporter = server.sign_in(reporter_key)
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    assert server.request("/api/session", cookie=reporter)[0] == {"name": "Site reporter"}
    assert server.request("/api/projects", cookie=viewer)[0][0]["permission"] == "read"
    assert server.request("/api/projects", cookie=outsider)[0][0]["id"] == SECOND_ORGANIZATION_PROJECT

    input_data = {
        "operation_id": str(uuid.uuid4()), "observed_at": None, "location": "Plantroom A",
        "note": "Supervisor observed a possible duct reroute. Written direction is pending.",
    }
    server.request(path, "POST", input_data, viewer, expected=404)
    server.request(path, cookie=outsider, expected=404)
    record = server.request(path, "POST", input_data, reporter)[0]
    assert server.request(path, "POST", input_data, reporter)[0] == record
    server.request(path, "POST", {**input_data, "note": "Different note"}, reporter, expected=409)
    assert server.request(path, cookie=viewer)[0]["observations"][0]["id"] == record["id"]
    full_path = f"{path}/{record['id']}"
    observed = server.request(full_path, cookie=viewer)[0]
    assert observed["actor_id"] == REPORTER and observed["note"] == input_data["note"]
    server.request(full_path, cookie=outsider, expected=404)

    server.request("/api/session", "DELETE", cookie=viewer, expected=204)
    server.request(full_path, cookie=viewer, expected=401)
    server.key(REPORTER, "Site reporter")
    server.request(path, cookie=reporter, expected=401)
    server.request("/api/session", "POST", {"key": reporter_key}, expected=401)
    print("PASS: same-origin sign-in, session rotation/logout, scoped capture and tamper-safe retries over HTTP")


def verify_connection_reuse(server):
    def backend():
        return server.sql(
            "SELECT pid FROM pg_stat_activity "
            f"WHERE usename = 'dd_web' AND application_name = '{APPLICATION_NAME}'"
        )

    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    path = f"/api/projects/{PROJECT}/observations"
    server.request(path, cookie=viewer)
    original = backend()
    assert original.isdecimal(), f"Expected one retained web backend, got {original!r}"
    server.request(path, cookie=viewer)
    assert backend() == original, "Sequential requests did not reuse the PostgreSQL backend."

    server.sql(f"DELETE FROM ductdelta.project_member WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'")
    server.request(path, cookie=viewer, expected=404)
    assert backend() == original, "Permission denial discarded a healthy backend."

    assert server.sql(f"SELECT pg_terminate_backend({original}, 5000)") == "t"
    server.request("/api/session", "DELETE", cookie=viewer, expected=204)
    replacement = backend()
    assert replacement.isdecimal() and replacement != original, "Expected a new backend after termination."
    server.request("/api/session", cookie=viewer, expected=401)
    print("PASS: PostgreSQL backend reuse, live permission revocation and recovery for the next mutation")


def verify_connection_limit(server):
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    path = "/api/projects"
    activity = (
        "SELECT count(*) FROM pg_stat_activity "
        f"WHERE usename = 'dd_web' AND application_name = '{APPLICATION_NAME}'"
    )
    admin = connection(server.database_socket, "dd_admin")
    with ThreadPoolExecutor(max_workers=16) as workers:
        with subprocess.Popen(
            [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", admin],
            env=server.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        ) as lock:
            try:
                lock.stdin.write("BEGIN; LOCK TABLE ductdelta.project_member; SELECT 'locked';\n")
                lock.stdin.flush()
                assert lock.stdout.readline().strip() == "locked"
                accounts = [(reporter, PROJECT), (outsider, SECOND_ORGANIZATION_PROJECT)] * 8
                requests = [workers.submit(server.request, path, cookie=cookie) for cookie, _ in accounts]
                deadline = time.monotonic() + 3
                while server.sql(f"{activity} AND wait_event_type = 'Lock'") != "16":
                    assert time.monotonic() < deadline, "Expected all admitted requests to wait for PostgreSQL."
                    time.sleep(0.02)
                server.request(path, cookie=reporter, expected=503)
                assert server.sql(activity) == "16", "Workspace exceeded its PostgreSQL connection limit."
            finally:
                lock.stdin.close()
                assert lock.wait(timeout=10) == 0
        for request, (_, project) in zip(requests, accounts):
            projects, _ = request.result()
            assert project in {record["id"] for record in projects}
            assert not {PROJECT, SECOND_ORGANIZATION_PROJECT}.issubset(record["id"] for record in projects)
    print("PASS: sixteen concurrent requests retained tenant scope and excess work received HTTP 503")


def verify_interrupted_capture(server):
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    server.sql("""
        CREATE SEQUENCE public.capture_attempt;
        CREATE FUNCTION public.interrupt_capture() RETURNS trigger
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
        BEGIN
            IF nextval('public.capture_attempt') = 1 THEN
                PERFORM pg_terminate_backend(pg_backend_pid());
            END IF;
            RETURN NEW;
        END;
        $$;
        CREATE TRIGGER interrupt_capture BEFORE INSERT ON ductdelta.observation
        FOR EACH ROW EXECUTE FUNCTION public.interrupt_capture();
    """)
    data = {"operation_id": str(uuid.uuid4()), "note": "Synthetic interrupted capture."}
    path = f"/api/projects/{PROJECT}/observations"
    server.request(path, "POST", data, reporter, expected=500)
    assert server.sql("SELECT last_value FROM public.capture_attempt") == "1"
    server.request(path, "POST", data, reporter)
    assert server.sql("SELECT last_value FROM public.capture_attempt") == "2"
    assert server.sql(
        f"SELECT count(*) FROM ductdelta.observation WHERE operation_id = '{data['operation_id']}'"
    ) == "1"
    print("PASS: interrupted capture was attempted once and the explicit retry saved one observation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="leave a synthetic workspace available on loopback")
    parser.add_argument("--port", type=int)
    parser.add_argument("--empty", action="store_true", help="start without sample companies or sign-in keys")
    parser.add_argument("--frontend", type=Path, default=ROOT / "frontend/.output/public")
    args = parser.parse_args()
    if args.empty and not args.serve:
        parser.error("--empty requires --serve.")
    if args.serve and not (args.frontend / "index.html").is_file():
        parser.error("Run pnpm install --frozen-lockfile and pnpm build in frontend before starting the workspace.")
    with workspace(args.port, frontend=args.frontend.resolve() if args.serve else None,
                   seed=not args.empty) as server:
        if not args.empty:
            verify(server)
        if not args.serve:
            verify_connection_reuse(server)
            verify_connection_limit(server)
            verify_interrupted_capture(server)
        if args.serve:
            print(f"Workspace: {server.origin}", flush=True)
            if not args.empty:
                grant_demo_capabilities(server)
                print(f"Synthetic access key: {server.key(REPORTER, 'Site reporter')}", flush=True)
            while True:
                time.sleep(1)


if __name__ == "__main__":
    main()
