#!/usr/bin/env python3
"""Verify company enrollment and project creation from an empty installation."""

import secrets
import subprocess

from check_workspace import CLI, OTHER_ORGANIZATION, REPORTER, VIEWER, connection, workspace


def verify(server):
    server.request("/api/companies", expected=401)
    server.request("/api/companies", "POST", {"company": "  ", "name": "Ada", "recovery_key": secrets.token_hex(32)}, expected=422)
    known_recovery = secrets.token_hex(32)
    created, headers = server.request(
        "/api/companies", "POST", {"company": "Basin Mechanical", "name": "Ada", "recovery_key": known_recovery}, expected=201,
    )
    assert created["recovery_key"] == known_recovery
    assert headers["Cache-Control"] == "no-store"
    assert "HttpOnly" in headers["Set-Cookie"]
    session = headers["Set-Cookie"].split(";", 1)[0]
    assert server.request("/api/session", cookie=session)[0] == {"name": "Ada"}
    companies = server.request("/api/companies", cookie=session)[0]
    assert companies == [{"id": created["id"], "name": "Basin Mechanical", "role": "admin"}]
    assert server.request("/api/projects", cookie=session)[0] == []
    path = f"/api/companies/{created['id']}/projects"
    assert server.request(path, cookie=session)[0] == []
    server.request(path, "POST", {"name": " \n", "operation_id": "73d22d2d-627e-49a5-8037-5aaf28c0e233"}, session, expected=422)
    draft = {"name": "Hospital plantroom", "operation_id": "66c8ae14-dd34-4620-89ff-c1e2ec81de01"}
    project = server.request(path, "POST", draft, session, expected=201)[0]
    assert server.request(path, "POST", draft, session, expected=201)[0] == project
    server.request(path, "POST", {**draft, "name": "Changed"}, session, expected=409)
    assert server.request(path, cookie=session)[0] == [project]
    assert server.request("/api/projects", cookie=session)[0] == [{**project, "permission": "capture"}]
    assert server.request(f"/api/projects/{project['id']}/overview", cookie=session)[0]["open_cases"] == 0
    other, other_headers = server.request(
        "/api/companies", "POST", {"company": "Other Mechanical", "name": "Other", "recovery_key": secrets.token_hex(32)}, expected=201,
    )
    outsider = other_headers["Set-Cookie"].split(";", 1)[0]
    assert other["id"] != created["id"]
    server.request(path, cookie=outsider, expected=404)
    server.request(path, "POST", draft, outsider, expected=404)

    alternate = server.request(f"/api/companies/{other['id']}/projects", "POST", draft, outsider, expected=201)[0]
    assert alternate["id"] != project["id"]
    assert server.sign_in(created["key"])
    replacement = secrets.token_hex(32)
    recovered, recovery_headers = server.request(
        "/api/account/recover", "POST", {"recovery_key": known_recovery, "replacement_recovery_key": replacement}, expected=200,
    )
    assert server.request("/api/companies", cookie=recovery_headers["Set-Cookie"].split(";", 1)[0])[0] == companies
    server.request("/api/session", cookie=session, expected=401)
    server.request("/api/session", "POST", {"key": created["key"]}, expected=401)
    server.request("/api/account/recover", "POST", {"recovery_key": known_recovery, "replacement_recovery_key": secrets.token_hex(32)}, expected=401)
    assert recovered["recovery_key"] == replacement
    # The replacement works even if the first recovery response is discarded.
    server.request("/api/account/recover", "POST", {
        "recovery_key": replacement, "replacement_recovery_key": secrets.token_hex(32),
    })
    server.request("/api/session", "POST", {"key": recovered["key"]}, expected=401)
    print("PASS: empty installation, company-specific setup, project replay and browser credential recovery")


def verify_upgrade(server):
    login = server.sign_in(server.key(REPORTER, "Existing reporter"))
    projects = server.request("/api/projects", cookie=login)[0]
    assert projects
    companies = server.request("/api/companies", cookie=login)[0]
    assert companies and all(company["role"] == "member" for company in companies)
    path = f"/api/companies/{companies[0]['id']}/projects"
    server.request(path, cookie=login, expected=404)
    company = companies[0]["id"]
    server.sql("CREATE ROLE dd_bootstrap LOGIN IN ROLE ductdelta_company_bootstrap;")

    def appoint(actor, database_login="dd_bootstrap"):
        return subprocess.run(
            [CLI, "appoint-first-admin", company, actor],
            env={
                **server.environment,
                "DUCTDELTA_DATABASE_URL": connection(server.database_socket, database_login),
            },
            capture_output=True, text=True, timeout=10,
        )

    assert appoint(REPORTER, "dd_web").returncode == 1
    assert appoint(OTHER_ORGANIZATION).returncode == 1
    server.request(path, cookie=login, expected=404)
    first = appoint(REPORTER)
    assert first.returncode == 0, first.stderr
    assert appoint(REPORTER).returncode == 0
    assert appoint(VIEWER).returncode == 1
    assert server.sql("SELECT count(*) FROM ductdelta.first_company_admin WHERE appointed_by = 'dd_bootstrap';") == "1"
    assert server.request("/api/projects", cookie=login)[0] == projects
    assert server.request("/api/companies", cookie=login)[0][0]["role"] == "admin"
    assert server.request(path, cookie=login)[0]
    print("PASS: populated upgrade preserves project access; operator appoints one legacy administrator")


if __name__ == "__main__":
    with workspace(seed=False) as server:
        verify(server)
    with workspace(seed_before="0008_company_setup.sql") as server:
        verify_upgrade(server)
