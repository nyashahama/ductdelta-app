#!/usr/bin/env python3
"""Verify queued invitation delivery against a loopback email provider."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import json
import os
import secrets
import subprocess
from threading import Event
import time
from uuid import uuid4

from check_company_team import accept, company
from check_workspace import ROOT, workspace


@contextmanager
def provider():
    requests = []
    release = Event()

    class Resend(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            assert self.path == "/emails"
            assert self.headers["Authorization"] == "Bearer integration-key"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.headers["Idempotency-Key"], body))
            recipient = body["to"][0]
            error_name = "validation_error"
            if recipient == "first@example.test":
                release.wait(timeout=3)
                retry = sum(payload["to"] == [recipient] for _, payload in requests) == 1
                status = 503 if retry else 200
            elif recipient == "before-layout@example.test" and "html" in body:
                status = 409
                error_name = "invalid_idempotent_request"
            elif recipient == "undeliverable@example.test":
                status = 422
            else:
                status = 200
            response = json.dumps({"id": str(uuid4())} if status == 200 else {"name": error_name}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

    with ThreadingHTTPServer(("127.0.0.1", 0), Resend) as server, ThreadPoolExecutor() as worker:
        running = worker.submit(server.serve_forever)
        try:
            yield f"http://127.0.0.1:{server.server_port}/emails", requests, release
        finally:
            release.set()
            server.shutdown()
            running.result(timeout=5)


def draft(email):
    return {"name": "Project reviewer", "role": "member", "email": email, "operation_id": str(uuid4())}


def verify(server, requests, release):
    path, admin = company(server, "Basin & <Mechanical>")
    _, outsider = company(server, "Separate Company")
    invitations = f"{path}/invitations"
    first = draft("first@example.test")
    assert server.request(invitations, cookie=admin)[0] == {"email_enabled": True, "deliveries": []}
    server.request(invitations, cookie=outsider, expected=404)
    server.request(invitations, "POST", first, outsider, expected=404)
    server.request(invitations, "POST", draft("a@example.test,b@example.test"), admin, expected=422)
    invitation, headers = server.request(invitations, "POST", first, admin, expected=202)
    assert headers["Cache-Control"] == "no-store"
    assert "token" not in invitation
    assert server.request(invitations, "POST", first, admin, expected=202)[0]["id"] == invitation["id"]
    server.request(invitations, "POST", {**first, "role": "admin"}, admin, expected=409)
    server.request(invitations, "POST", draft("first@example.test"), admin, expected=409)

    def delivery(invite_id, state):
        for _ in range(160):
            result = server.request(invitations, cookie=admin)[0]["deliveries"]
            for entry in result:
                if entry["id"] == invite_id and entry["state"] == state:
                    return entry
            time.sleep(0.05)
        raise AssertionError(f"Invitation did not reach {state}")

    assert delivery(invitation["id"], "queued")["email"] == first["email"]
    release.set()
    assert delivery(invitation["id"], "accepted")["email"] == first["email"]
    assert len(requests) == 2 and requests[0] == requests[1], requests
    idempotency_key, message = requests[0]
    assert idempotency_key == f"invitation/{invitation['id']}"
    assert message["from"] == "DuctDelta <invites@example.test>"
    assert message["to"] == [first["email"]] and "Basin & <Mechanical>" in message["text"]
    url, = [line for line in message["text"].splitlines() if line.startswith(server.origin)]
    assert url.startswith(server.origin + "/#invite=")
    assert message.get("reply_to") == "support@example.test", "Invitation replies must reach support"
    html = message["html"]
    assert "Basin &amp; &lt;Mechanical&gt;" in html and "<Mechanical>" not in html
    assert f'href="{url}"' in html and "Accept invitation" in html
    assert 'href="mailto:support@example.test"' in html
    token = url.split("=", 1)[1]
    assert token not in json.dumps(server.request(invitations, cookie=admin)[0])
    result, _ = accept(server, token)
    assert result["id"] == path.rsplit("/", 1)[-1]
    accept(server, token, expected=404)
    bad = server.request(invitations, "POST", draft("undeliverable@example.test"), admin, expected=202)[0]
    delivery(bad["id"], "needs_attention")
    assert len(requests) == 3
    server.request(f"{invitations}/{bad['id']}", "DELETE", cookie=admin, expected=204)
    assert server.request(invitations, cookie=admin)[0]["deliveries"] == []
    previous = server.request(invitations, "POST", draft("before-layout@example.test"), admin, expected=202)[0]
    delivery(previous["id"], "accepted")
    assert len(requests) == 5
    styled, legacy = requests[-2:]
    assert styled[0] == legacy[0] == f"invitation/{previous['id']}"
    assert legacy[1] == {key: value for key, value in styled[1].items() if key not in {"html", "reply_to"}}
    print("PASS: scoped email invite, queued write, same payload retry, one-time acceptance and visible terminal failure")


def mail_environment(url):
    return {
        "DUCTDELTA_RESEND_API_KEY": "integration-key",
        "DUCTDELTA_RESEND_FROM": "DuctDelta <invites@example.test>",
        "DUCTDELTA_INVITE_SIGNING_KEY": "e1" * 32,
        "DUCTDELTA_RESEND_API_URL": url,
        "DUCTDELTA_EMAIL_REPLY_TO": "support@example.test",
    }


def browser_check():
    if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
        raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the path to playwright/index.mjs.")
    frontend = ROOT / "frontend/.output/public"
    if not (frontend / "index.html").is_file():
        raise SystemExit("Build the Nuxt frontend before running the browser check.")
    (ROOT / "artifacts").mkdir(exist_ok=True)
    setup_code = secrets.token_hex(32)
    with provider() as (url, requests, _), workspace(
        seed=False, frontend=frontend,
        service_env={**mail_environment(url), "DUCTDELTA_COMPANY_SETUP_CODE": setup_code},
    ) as server:
        environment = {**os.environ, "DD_INVITE_ORIGIN": server.origin, "DD_COMPANY_SETUP_CODE": setup_code}
        subprocess.run(["node", "scripts/check_invitation_email.mjs", "create"], cwd=ROOT, env=environment, check=True)
        assert len(requests) == 1 and requests[0][1]["to"] == ["site@example.test"]
        text = requests[0][1]["text"]
        link, = [line for line in text.splitlines() if line.startswith(server.origin)]
        environment["DD_INVITE_LINK"] = link
        subprocess.run(["node", "scripts/check_invitation_email.mjs", "accept"], cwd=ROOT, env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", action="store_true")
    if parser.parse_args().browser:
        browser_check()
        return
    with provider() as (url, requests, release), workspace(seed=False, service_env=mail_environment(url)) as server:
        verify(server, requests, release)
    with workspace(seed=False) as server:
        path, admin = company(server, "Manual invitations")
        base = f"{path}/invitations"
        assert server.request(base, cookie=admin)[0] == {"email_enabled": False, "deliveries": []}
        server.request(base, "POST", draft("disabled@example.test"), admin, expected=503)
        assert server.request(f"{path}/team", cookie=admin)[0]["invitations"] == []
        print("PASS: disabled email creates no invitation")


if __name__ == "__main__":
    main()
