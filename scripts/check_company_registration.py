#!/usr/bin/env python3
"""Check controlled company registration without changing invitation or recovery behavior."""

import secrets

from check_company_team import accept, cookie, invite
from check_workspace import workspace


def verify(server, code):
    path = "/api/company-registration"
    assert server.request(path)[0] == {"setup_code_required": code is not None}
    registration = {"company": "Basin Mechanical", "name": "Owner", "recovery_key": secrets.token_hex(32)}
    if code is not None:
        server.request("/api/companies", "POST", registration, expected=403)
        server.request("/api/companies", "POST", {**registration, "setup_code": "wrong"}, expected=403)
        assert server.sql("SELECT count(*) FROM ductdelta.organization;") == "0"
        registration["setup_code"] = code
    company, headers = server.request("/api/companies", "POST", registration, expected=201)
    link = invite(server, f"/api/companies/{company['id']}", cookie(headers), "Site lead")
    assert accept(server, link["token"])[0]["id"] == company["id"]


if __name__ == "__main__":
    with workspace(seed=False) as server:
        verify(server, None)
    code = secrets.token_hex(32)
    with workspace(seed=False, service_env={"DUCTDELTA_COMPANY_SETUP_CODE": code}) as server:
        verify(server, code)
    print("PASS: controlled and open company setup; a setup code never applies to an invited team member")
