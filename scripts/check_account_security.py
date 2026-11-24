#!/usr/bin/env python3
"""Verify account recovery and company sign-in with disposable providers."""

from concurrent.futures import ThreadPoolExecutor
import json
import secrets
import time

from check_email_sign_in import code_for, request_code, verify
from check_invitation_email import mail_environment, provider
from check_workspace import workspace

SECURITY = "/api/account/security"


def recovery(server, messages):
    old_email = "old@example.test"
    new_email = "new@example.test"
    creation = request_code(server, old_email, "company", company="Recovery shop", name="Owner")
    original = verify(server, creation, code_for(messages, creation, old_email))
    company = server.request("/api/companies", cookie=original)[0]
    assert server.request(SECURITY, cookie=original)[0]["email"] == old_email
    recovery_path = SECURITY + "/recovery-code"
    first = server.request(recovery_path, "POST", {}, original, expected=201)[0]["code"]
    offline = server.request(recovery_path, "POST", {}, original, expected=201)[0]["code"]
    assert first != offline and len(offline) == 64
    assert offline not in json.dumps(server.request(SECURITY, cookie=original)[0])
    server.request("/api/account/email-codes", "POST", {
        "email": new_email, "purpose": "recover", "key": first,
    }, expected=401)
    challenge = request_code(server, new_email, "recover", key=offline)
    confirmed = code_for(messages, challenge, new_email)
    pending_sign_in = request_code(server, old_email)
    old_login = code_for(messages, pending_sign_in, old_email)
    server.request(SECURITY + "/recovery-code", "POST", {}, expected=401)

    def accept():
        try:
            return verify(server, challenge, confirmed)
        except AssertionError as error:
            assert error.args[0][2] == 401, error
            return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        current, = filter(None, pool.map(lambda _: accept(), range(2)))
    assert server.request("/api/companies", cookie=current)[0] == company
    assert server.request(SECURITY, cookie=current)[0]["email"] == new_email
    assert server.request(SECURITY, cookie=current)[0]["has_recovery_code"] is False
    server.request("/api/session", cookie=original, expected=401)
    verify(server, pending_sign_in, old_login, expected=401)
    server.request("/api/account/email-codes", "POST", {
        "email": "another@example.test", "purpose": "recover", "key": offline,
    }, expected=401)
    pending = request_code(server, old_email)
    assert not any(key.startswith(f"email-code/{pending}/") for key, _ in messages)
    for _ in range(80):
        notices = [mail for key, mail in messages if key.startswith(f"email-notice/{challenge}/")]
        if notices:
            break
        time.sleep(0.1)
    assert len(notices) == 1 and notices[0]["to"] == [old_email]
    assert new_email not in notices[0]["text"] and offline not in notices[0]["text"]
    server.sql("UPDATE ductdelta.web_session SET created_at = clock_timestamp() - interval '20 minutes'")
    server.request(recovery_path, "POST", {}, current, expected=403)
    print("PASS: saved recovery, verified email change, rotation, session revocation and notification to the previous address")


if __name__ == "__main__":
    with provider() as (url, messages, release), workspace(service_env={
        **mail_environment(url), "DUCTDELTA_EMAIL_SIGN_IN": "1",
    }) as server:
        release.set()
        recovery(server, messages)
