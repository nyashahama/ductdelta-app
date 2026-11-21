#!/usr/bin/env python3
"""Verify company enrollment and project creation from an empty installation."""

from check_workspace import workspace


def verify(server):
    server.request("/api/companies", expected=401)
    server.request("/api/companies", "POST", {"company": "  ", "name": "Ada"}, expected=422)
    created, headers = server.request(
        "/api/companies", "POST", {"company": "Basin Mechanical", "name": "Ada"}, expected=201,
    )
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
        "/api/companies", "POST", {"company": "Other Mechanical", "name": "Other"}, expected=201,
    )
    outsider = other_headers["Set-Cookie"].split(";", 1)[0]
    assert other["id"] != created["id"]
    server.request(path, cookie=outsider, expected=404)
    server.request(path, "POST", draft, outsider, expected=404)

    assert server.sign_in(created["key"])
    recovered, recovery_headers = server.request(
        "/api/account/recover", "POST", {"recovery_key": created["recovery_key"]}, expected=200,
    )
    recovered_session = recovery_headers["Set-Cookie"].split(";", 1)[0]
    server.request("/api/session", cookie=session, expected=401)
    server.request("/api/session", "POST", {"key": created["key"]}, expected=401)
    server.request("/api/account/recover", "POST", {"recovery_key": created["recovery_key"]}, expected=401)
    assert recovered["recovery_key"] != created["recovery_key"]
    assert server.sign_in(recovered["key"])
    assert server.request("/api/companies", cookie=recovered_session)[0] == companies
    print("PASS: empty installation, company-specific setup, project replay and browser credential recovery")


if __name__ == "__main__":
    with workspace(seed=False) as server:
        verify(server)
