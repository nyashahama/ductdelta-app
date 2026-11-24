#!/usr/bin/env python3
"""Verify email authentication against the disposable database and loopback mail provider."""

from concurrent.futures import ThreadPoolExecutor
import argparse
from hashlib import sha256
import json
import os
import re
import secrets
import subprocess
import time

from check_invitation_email import draft, mail_environment, provider
from check_workspace import REPORTER, ROOT, VIEWER, workspace

CODES = "/api/account/email-codes"
VERIFY = CODES + "/verify"
EMAIL = "owner@example.test"
SETUP = secrets.token_hex(32)


def code_for(requests, challenge, email):
    for _ in range(100):
        for identifier, message in list(requests):
            if identifier == f"email-code/{challenge}":
                assert message["to"] == [email]
                code = re.search(r"\b[0-9]{8}\b", message["text"])[0]
                assert code in message["html"]
                return code
        time.sleep(0.1)
    raise AssertionError("The loopback provider did not receive the expected code")


def request_code(server, email, purpose="sign_in", **details):
    result, _ = server.request(CODES, "POST", {"email": email, "purpose": purpose, **details}, expected=202)
    return result["id"]


def verify(server, challenge, code, expected=204):
    _, headers = server.request(VERIFY, "POST", {"id": challenge, "code": code}, expected=expected)
    if expected == 204:
        cookie = headers["Set-Cookie"]
        assert "HttpOnly" in cookie and "SameSite=Strict" in cookie
        return cookie.split(";", 1)[0]


def allow_resend(server, email):
    server.sql(f"UPDATE ductdelta.email_code SET created_at = created_at - interval '2 minutes' WHERE email = '{email}'")


def check(server, messages):
    assert server.request("/api/account/email-sign-in")[0] == {"enabled": True}
    registration = {"email": EMAIL, "purpose": "company", "company": "Test Mechanical", "name": "Test Owner"}
    server.request(CODES, "POST", registration, expected=403)
    challenge = request_code(server, EMAIL, "company", company="Test Mechanical", name="Test Owner", setup_code=SETUP)
    code = code_for(messages, challenge, EMAIL)
    assert server.sql("SELECT count(*) FROM ductdelta.organization WHERE name = 'Test Mechanical'") == "0"
    verify(server, challenge, "99999999" if code != "99999999" else "00000000", expected=401)
    owner = verify(server, challenge, code)
    verify(server, challenge, code, expected=401)
    companies = server.request("/api/companies", cookie=owner)[0]
    assert len(companies) == 1 and companies[0]["name"] == "Test Mechanical"
    company = f"/api/companies/{companies[0]['id']}"
    server.request("/api/companies", "POST", {
        "company": "Legacy", "name": "No email", "recovery_key": secrets.token_hex(32), "setup_code": SETUP,
    }, expected=403)
    allow_resend(server, EMAIL)
    challenge = request_code(server, "  OWNER@Example.test ")
    code = code_for(messages, challenge, EMAIL)
    with ThreadPoolExecutor(max_workers=2) as pool:
        def attempt():
            try:
                verify(server, challenge, code)
                return True
            except AssertionError as error:
                assert error.args[0][2] == 401, error
                return False
        assert sorted(pool.map(lambda _: attempt(), range(2))) == [False, True]

    unknown = request_code(server, "unknown@example.test")
    verify(server, unknown, "00000000", expected=401)
    assert all(identifier != f"email-code/{unknown}" for identifier, _ in messages)
    print("PASS: email is verified before setup, sign-in is private, and concurrent replay creates one session")

    retry_email = "first@example.test"
    retry = request_code(server, retry_email, "company", company="Retry Mechanical", name="Retry Owner", setup_code=SETUP)
    delivery = f"email-code/{retry}"
    for _ in range(100):
        matching = [body for identifier, body in list(messages) if identifier == delivery]
        if len(matching) == 2:
            break
        time.sleep(0.1)
    assert len(matching) == 2 and matching[0] == matching[1]
    verify(server, retry, code_for(messages, retry, retry_email))
    print("PASS: transient provider errors retry the same message and code")

    private, _ = server.request(company + "/invitations", "POST",
                                {"name": "Test Member", "role": "member"}, owner, expected=201)
    token = private["token"]
    server.request("/api/invitations/accept", "POST", {
        "token": token, "use_current_account": False, "recovery_key": secrets.token_hex(32),
    }, expected=403)
    challenge = request_code(server, "member@example.test", "invite", token=token)
    member = verify(server, challenge, code_for(messages, challenge, "member@example.test"))
    assert server.request("/api/companies", cookie=member)[0][0]["role"] == "member"
    server.request(CODES, "POST", {"email": "member@example.test", "purpose": "invite", "token": token}, expected=404)

    invitation_email = "recipient@example.test"
    sent, _ = server.request(company + "/invitations", "POST", draft(invitation_email), owner, expected=202)
    for _ in range(100):
        message = next((body for identifier, body in list(messages) if identifier == f"invitation/{sent['id']}"), None)
        if message:
            break
        time.sleep(0.1)
    assert message
    token = re.search(r"#invite=([0-9a-f]{64})", message["text"])[1]
    server.request(CODES, "POST", {"email": "wrong@example.test", "purpose": "invite", "token": token}, expected=404)
    challenge = request_code(server, invitation_email, "invite", token=token)
    code = code_for(messages, challenge, invitation_email)
    server.request(f"{company}/invitations/{sent['id']}", "DELETE", cookie=owner, expected=204)
    verify(server, challenge, code, expected=404)

    existing, _ = server.request(company + "/invitations", "POST",
                                 {"name": "Migrating Member", "role": "member"}, owner, expected=201)
    legacy_key = server.key(VIEWER, "Existing Viewer")
    recovery_key = secrets.token_hex(32)
    recovery_digest = sha256(recovery_key.encode()).hexdigest()
    session_token = secrets.token_hex(32)
    session_digest = sha256(session_token.encode()).hexdigest()
    access_digest = sha256(legacy_key.encode()).hexdigest()
    server.sql(f"INSERT INTO ductdelta.web_recovery_key VALUES ('{VIEWER}', decode('{recovery_digest}', 'hex'))")
    assert server.sql(f"SELECT ductdelta.web_login(decode('{access_digest}', 'hex'), decode('{session_digest}', 'hex'))") == "t"
    migrating_email = "migrating@example.test"
    challenge = request_code(server, migrating_email, "upgrade", key=recovery_key, token=existing["token"])
    migrated_member = verify(server, challenge, code_for(messages, challenge, migrating_email))
    assert server.request("/api/session", cookie=migrated_member)[0]["name"] == "Existing Viewer"
    assert any(item["id"] == companies[0]["id"] for item in server.request("/api/companies", cookie=migrated_member)[0])
    server.request("/api/session", cookie=f"dd_session={session_token}", expected=401)
    assert server.sql(f"SELECT count(*) FROM ductdelta.web_recovery_key WHERE actor_id = '{VIEWER}'") == "0"
    print("PASS: invitations require verified email, remain scoped and revocable, and can migrate an existing account")

    key = server.key(REPORTER, "Migrating reporter")
    server.request("/api/session", "POST", {"key": key}, expected=403)
    upgrade_email = "existing@example.test"
    challenge = request_code(server, upgrade_email, "upgrade", key=key)
    migrated = verify(server, challenge, code_for(messages, challenge, upgrade_email))
    assert server.request("/api/projects", cookie=migrated)[0]
    assert server.sql(f"SELECT actor_id FROM ductdelta.web_access_key WHERE email = '{upgrade_email}'") == REPORTER
    server.request(CODES, "POST", {"email": "other@example.test", "purpose": "upgrade", "key": key}, expected=401)

    allow_resend(server, upgrade_email)
    challenge = request_code(server, upgrade_email)
    code = code_for(messages, challenge, upgrade_email)
    throttled = request_code(server, upgrade_email)
    assert server.sql(f"SELECT count(*) FROM ductdelta.email_code WHERE id = '{throttled}'") == "0"
    wrong = "99999999" if code != "99999999" else "00000000"
    for _ in range(5):
        verify(server, challenge, wrong, expected=401)
    verify(server, challenge, code, expected=401)
    allow_resend(server, upgrade_email)
    challenge = request_code(server, upgrade_email)
    code = code_for(messages, challenge, upgrade_email)
    server.sql(f"UPDATE ductdelta.email_code SET expires_at = statement_timestamp() WHERE id = '{challenge}'")
    verify(server, challenge, code, expected=401)
    print("PASS: legacy migration keeps the actor and grants, retires the key, and codes expire and enforce attempt and resend limits")


def browser_check(server, messages):
    environment = {
        **os.environ, "DD_EMAIL_ORIGIN": server.origin, "DD_EMAIL_SETUP": SETUP,
        "DD_EMAIL_LEGACY": server.key(REPORTER, "Browser reporter"),
    }
    with subprocess.Popen(
        ["node", "scripts/check_email_sign_in.mjs"], cwd=ROOT, env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    ) as chromium:
        try:
            for line in chromium.stdout:
                if line.startswith("PASS:"):
                    print(line, end="")
                    continue
                request = json.loads(line)
                print(code_for(messages, request["id"], request["email"]), file=chromium.stdin, flush=True)
            assert chromium.wait(timeout=10) == 0
        finally:
            if chromium.poll() is None:
                chromium.terminate()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", action="store_true")
    browser = parser.parse_args().browser
    frontend = ROOT / "frontend/.output/public" if browser else None
    if browser and (
        not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE") or not (frontend / "index.html").is_file()
    ):
        raise SystemExit("Build the frontend and set DUCTDELTA_PLAYWRIGHT_MODULE before running the browser check.")
    with provider() as (url, messages, release), workspace(frontend=frontend, service_env={
        **mail_environment(url), "DUCTDELTA_EMAIL_SIGN_IN": "1", "DUCTDELTA_COMPANY_SETUP_CODE": SETUP,
    }) as server:
        release.set()
        if browser:
            browser_check(server, messages)
        else:
            check(server, messages)
