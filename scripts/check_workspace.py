#!/usr/bin/env python3
"""Verify the signed-in workspace over HTTP using a disposable PostgreSQL cluster."""

import argparse
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
def workspace(port=None, *, backup=None, frontend=None):
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
                server.sql(migration.read_text())
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
            [CLI, "serve"], cwd=ROOT, env={
                **environment,
                "DUCTDELTA_DATABASE_URL": connection(database_socket, "dd_web"),
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="leave a synthetic workspace available on loopback")
    parser.add_argument("--port", type=int)
    parser.add_argument("--frontend", type=Path, default=ROOT / "frontend/dist/client")
    args = parser.parse_args()
    if args.serve and not (args.frontend / "_shell.html").is_file():
        parser.error("Run npm ci and npm run build in frontend before starting the workspace.")
    with workspace(args.port, frontend=args.frontend.resolve() if args.serve else None) as server:
        verify(server)
        if args.serve:
            if server.sql("SELECT to_regclass('ductdelta.project_workflow_grant')"):
                grant_demo_capabilities(server)
            key = server.key(REPORTER, "Site reporter")
            print(f"Workspace: {server.origin}\nSynthetic access key: {key}", flush=True)
            while True:
                time.sleep(1)


if __name__ == "__main__":
    main()
