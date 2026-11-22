#!/usr/bin/env python3
"""Check account-level session controls over HTTP with independent cookies."""

import secrets
import uuid
from concurrent.futures import ThreadPoolExecutor

from check_company_team import accept, company, cookie, invite
from check_workspace import REPORTER, workspace

SESSIONS = "/api/account/sessions"
LEGACY_KEY = "1" * 64
LEGACY_TOKEN = "2" * 64


def create_legacy_session(server):
    server.sql(
        "INSERT INTO ductdelta.web_access_key VALUES "
        f"('{REPORTER}', 'Legacy reporter', sha256(convert_to('{LEGACY_KEY}', 'UTF8')), 'infinity');"
        "INSERT INTO ductdelta.web_session VALUES "
        f"(sha256(convert_to('{LEGACY_TOKEN}', 'UTF8')), '{REPORTER}', "
        f"sha256(convert_to('{LEGACY_KEY}', 'UTF8')), statement_timestamp() + interval '30 minutes');"
    )


def sessions(server, browser):
    rows, headers = server.request(SESSIONS, cookie=browser)
    assert headers["Cache-Control"] == "no-store"
    assert all(set(row) == {"id", "created_at", "expires_at", "current"} for row in rows)
    assert all(uuid.UUID(row["id"]).version == 4 for row in rows)
    assert len({row["id"] for row in rows}) == len(rows)
    assert sum(row["current"] for row in rows) == 1
    return rows


def current_id(server, browser):
    return next(row["id"] for row in sessions(server, browser) if row["current"])


def verify(server):
    server.request(SESSIONS, expected=401)
    server.request(SESSIONS, "DELETE", expected=401)
    legacy = sessions(server, f"dd_session={LEGACY_TOKEN}")
    assert len(legacy) == 1 and legacy[0]["created_at"] is None

    recovery = secrets.token_hex(32)
    founder, headers = server.request(
        "/api/companies", "POST",
        {"company": "Basin Mechanical", "name": "Ada", "recovery_key": recovery},
        expected=201,
    )
    server.request("/api/session", "DELETE", cookie=cookie(headers), expected=204)
    first = server.sign_in(founder["key"])
    second = server.sign_in(founder["key"])
    third = server.sign_in(founder["key"])
    assert len({first, second, third}) == 3
    first_id, second_id, third_id = (current_id(server, browser) for browser in (first, second, third))
    initial = sessions(server, first)
    assert len(initial) == 3 and all(row["created_at"] and row["expires_at"] for row in initial)
    assert {row["id"] for row in initial} == {first_id, second_id, third_id}

    west, west_admin = company(server, "West Mechanical")
    accept(server, invite(server, west, west_admin, "Ada")["token"], existing=first)
    assert [membership["role"] for membership in server.request("/api/companies", cookie=first)[0]] == ["admin", "member"]
    west_id = current_id(server, west_admin)
    server.request(f"{SESSIONS}/{west_id}", "DELETE", cookie=first, expected=404)
    server.request(f"{SESSIONS}/{first_id}", "DELETE", cookie=west_admin, expected=404)
    server.request(f"{SESSIONS}/{first_id}", "DELETE", cookie=first, expected=404)
    server.request(f"{SESSIONS}/{second_id}", "DELETE", cookie=first, origin="https://invalid.example", expected=403)
    assert sessions(server, first) == initial

    _, headers = server.request(f"{SESSIONS}/{second_id}", "DELETE", cookie=first, expected=204)
    assert headers.get("Set-Cookie") is None
    server.request("/api/session", cookie=second, expected=401)
    server.request(SESSIONS, cookie=second, expected=401)
    server.request(SESSIONS, "DELETE", cookie=second, expected=401)
    assert current_id(server, third) == third_id
    assert current_id(server, first) == first_id
    server.request(f"{SESSIONS}/{second_id}", "DELETE", cookie=first, expected=404)

    fourth = server.sign_in(founder["key"])
    expired_id = current_id(server, fourth)
    server.sql(
        "UPDATE ductdelta.web_session SET expires_at = statement_timestamp() - interval '1 hour' "
        f"WHERE id = '{expired_id}';"
    )
    assert expired_id not in {row["id"] for row in sessions(server, first)}
    server.request(SESSIONS, cookie=fourth, expected=401)

    extra = server.sign_in(founder["key"])
    _, headers = server.request(SESSIONS, "DELETE", cookie=first, expected=204)
    assert headers.get("Set-Cookie") is None
    server.request(SESSIONS, "DELETE", cookie=first, expected=204)
    assert [row["id"] for row in sessions(server, first)] == [first_id]
    for browser in (third, extra):
        server.request("/api/session", cookie=browser, expected=401)
    assert current_id(server, west_admin) == west_id

    signed_out = server.sign_in(founder["key"])
    server.request("/api/session", "DELETE", cookie=signed_out, expected=204)
    assert [row["id"] for row in sessions(server, first)] == [first_id]
    before_recovery = server.sign_in(founder["key"])
    _, headers = server.request(
        "/api/account/recover", "POST",
        {"recovery_key": recovery, "replacement_recovery_key": secrets.token_hex(32)},
    )
    for browser in (first, before_recovery):
        server.request(SESSIONS, cookie=browser, expected=401)
    recovered = sessions(server, cookie(headers))
    assert len(recovered) == 1 and recovered[0]["id"] != first_id
    assert current_id(server, west_admin) == west_id
    print("PASS: legacy sessions, account-scoped inventory, individual and bulk revocation, sign-out and recovery")


def verify_competing_revocations(server):
    founder, _ = server.request(
        "/api/companies", "POST",
        {"company": "South Mechanical", "name": "Quinn", "recovery_key": secrets.token_hex(32)},
        expected=201,
    )
    browsers = [server.sign_in(founder["key"]) for _ in range(2)]
    session_ids = [current_id(server, browser) for browser in browsers]

    def revoke_others(browser):
        try:
            server.request(SESSIONS, "DELETE", cookie=browser, expected=204)
        except AssertionError as error:
            assert error.args[0][2] == 401, error
            return False
        return True

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(revoke_others, browsers))
    assert sum(results) == 1
    winner = results.index(True)
    assert [row["id"] for row in sessions(server, browsers[winner])] == [session_ids[winner]]
    server.request(SESSIONS, cookie=browsers[1 - winner], expected=401)
    print("PASS: competing bulk revocations leave exactly one authenticated caller")


if __name__ == "__main__":
    with workspace(
        seed_before="0008_company_setup.sql",
        before_migration=("0016_account_sessions.sql", create_legacy_session),
    ) as server:
        verify(server)
        verify_competing_revocations(server)
