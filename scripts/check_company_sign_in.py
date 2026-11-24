#!/usr/bin/env python3
"""Verify Entra sign-in and company MFA enforcement with signed loopback ID tokens."""

import argparse
import base64
from contextlib import contextmanager
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
import time
from urllib.parse import parse_qs, urlencode, urlsplit
from uuid import uuid4

from check_email_sign_in import code_for, request_code, verify
from check_invitation_email import mail_environment, provider
from check_workspace import ROOT, workspace

TENANT = str(uuid4())
CLIENT = str(uuid4())
OWNER = str(uuid4())
SECRET = "loopback-entra-test"
CALLBACK = "/api/account/sso/callback"
START = "/api/account/sso/start"
EMAIL = "owner@sso.example.test"


def base64url(binary):
    return base64.urlsafe_b64encode(binary).rstrip(b"=")


@contextmanager
def entra_provider():
    with TemporaryDirectory() as directory:
        key = Path(directory) / "issuer.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key],
                       check=True, capture_output=True)
        modulus = subprocess.check_output(["openssl", "rsa", "-in", key, "-modulus", "-noout"]).strip().split(b"=")[1]
        jwks = {"keys": [{"kty": "RSA", "kid": "loopback", "alg": "RS256", "use": "sig",
                         "n": base64url(bytes.fromhex(modulus.decode())).decode(), "e": "AQAB"}]}
        grants = {}

        class Entra(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def send_json(self, data, status=200):
                body = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urlsplit(self.path)
                if url.path == f"/{TENANT}/discovery/v2.0/keys":
                    self.send_json(jwks)
                elif url.path == f"/{TENANT}/oauth2/v2.0/authorize":
                    request = {name: values[0] for name, values in parse_qs(url.query).items()}
                    code = str(uuid4())
                    grants[code] = (request, {})
                    self.send_response(303)
                    self.send_header("Location", request["redirect_uri"] + "?" + urlencode(
                        {"code": code, "state": request["state"]}))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    self.send_error(404)

            def do_POST(self):
                if self.path != f"/{TENANT}/oauth2/v2.0/token":
                    self.send_error(404)
                    return
                data = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
                code = data.get("code", [""])[0]
                if code not in grants:
                    self.send_json({"error": "invalid_grant"}, 400)
                    return
                request, overrides = grants.pop(code)
                overrides = overrides.copy()
                invalid_signature = overrides.pop("invalid_signature", False)
                assert data["client_id"] == [CLIENT] and data["client_secret"] == [SECRET]
                assert data["redirect_uri"] == [request["redirect_uri"]]
                assert request["code_challenge_method"] == "S256"
                assert base64url(sha256(data["code_verifier"][0].encode()).digest()).decode() == request["code_challenge"]
                now = int(time.time())
                claims = {"iss": f"{origin}/{TENANT}/v2.0", "sub": "local-id-token-subject",
                          "aud": CLIENT, "nonce": request["nonce"], "iat": now, "exp": now + 1800,
                          "tid": TENANT, "oid": OWNER, "email": EMAIL, "acrs": ["c1"], **overrides}
                if "profile" not in request["scope"].split():
                    del claims["oid"]
                encoded = b".".join(base64url(json.dumps(part).encode()) for part in (
                    {"alg": "RS256", "kid": "loopback"}, claims,
                ))
                signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=encoded,
                                           capture_output=True, check=True).stdout
                if invalid_signature:
                    signature = bytes([signature[0] ^ 1]) + signature[1:]
                self.send_json({"access_token": "loopback", "token_type": "Bearer",
                                "id_token": (encoded + b"." + base64url(signature)).decode()})

        with ThreadingHTTPServer(("127.0.0.2", 0), Entra) as http:
            origin = f"http://127.0.0.2:{http.server_port}"
            worker = Thread(target=http.serve_forever)
            worker.start()
            try:
                yield origin, grants
            finally:
                http.shutdown()
                worker.join(timeout=5)


def setup_company(server, messages):
    challenge = request_code(server, EMAIL, "company", company="Entra Mechanical", name="Entra Owner")
    ordinary = verify(server, challenge, code_for(messages, challenge, EMAIL))
    company = server.request("/api/companies", cookie=ordinary)[0][0]["id"]
    project = server.request(f"/api/companies/{company}/projects", "POST", {
        "name": "Plantroom", "operation_id": str(uuid4()),
    }, ordinary, expected=201)[0]["id"]
    actor = server.sql(f"SELECT actor_id FROM ductdelta.web_access_key WHERE email = '{EMAIL}'")
    server.sql(f"SELECT ductdelta.configure_company_entra('{company}','{TENANT}')")
    server.sql(f"SELECT ductdelta.link_company_entra('{company}','{actor}','{OWNER}')")
    server.sql(f"SELECT ductdelta.configure_company_entra('{company}','{TENANT}','c1')")
    assert server.sql("SELECT has_function_privilege('dd_web','ductdelta.link_company_entra(uuid,uuid,uuid)','EXECUTE')") == "f"
    return ordinary, company, project, actor


def check(server, messages, origin, grants):
    ordinary, company, project, actor = setup_company(server, messages)
    assert server.request("/api/account/sso/companies", cookie=ordinary)[0] == [
        {"id": company, "name": "Entra Mechanical"},
    ]
    server.request(f"/api/companies/{company}/team", cookie=ordinary, expected=403)
    server.request(f"/api/projects/{project}/overview", cookie=ordinary, expected=403)
    server.request(f"/api/projects/{project}/cases", cookie=ordinary, expected=403)
    server.request(f"/api/projects/{project}/observations", cookie=ordinary)
    staff_email = "finance@sso.example.test"
    staff_challenge = request_code(server, staff_email, "company", company="Staff Mechanical", name="Finance")
    staff = verify(server, staff_challenge, code_for(messages, staff_challenge, staff_email))
    staff_actor = server.sql(f"SELECT actor_id FROM ductdelta.web_access_key WHERE email = '{staff_email}'")
    server.sql(f"""INSERT INTO ductdelta.organization_member VALUES ('{company}','{staff_actor}','member');
                   INSERT INTO ductdelta.project_member (organization_id,project_id,actor_id,permission)
                   VALUES ('{company}','{project}','{staff_actor}','read');""")
    server.request(f"/api/projects/{project}/overview", cookie=staff)
    server.sql(f"INSERT INTO ductdelta.project_workflow_grant VALUES ('{company}','{project}','{staff_actor}','finance')")
    server.request(f"/api/projects/{project}/overview", cookie=staff, expected=403)
    challenge = request_code(server, EMAIL, "company", company="Other Mechanical", name="Entra Owner")
    other_session = verify(server, challenge, code_for(messages, challenge, EMAIL))
    other = next(item["id"] for item in server.request("/api/companies", cookie=other_session)[0] if item["id"] != company)
    server.sql(f"SELECT ductdelta.configure_company_entra('{other}','{TENANT}')")
    server.sql(f"SELECT ductdelta.link_company_entra('{other}','{actor}','{OWNER}')")
    server.sql(f"SELECT ductdelta.configure_company_entra('{other}','{TENANT}','c1')")

    def start():
        payload, headers = server.request(START, "POST", {"company": company})
        url = urlsplit(payload["url"])
        assert url.geturl().startswith(f"{origin}/{TENANT}/oauth2/v2.0/authorize?")
        request = {name: values[0] for name, values in parse_qs(url.query).items()}
        assert request["redirect_uri"] == server.origin + CALLBACK
        assert set(request["scope"].split()) == {"openid", "profile"}
        assert json.loads(request["claims"]) == {"id_token": {"acrs": {"essential": True, "value": "c1"}}}
        assert "HttpOnly" in headers["Set-Cookie"] and "SameSite=Lax" in headers["Set-Cookie"]
        return request, headers["Set-Cookie"].split(";", 1)[0]

    for overrides in ({"nonce": "wrong"}, {"tid": str(uuid4())}, {"aud": str(uuid4())},
                      {"oid": str(uuid4())}, {"acrs": []}, {"iss": origin},
                      {"invalid_signature": True}, {"nbf": int(time.time()) + 300}, {"exp": 1}, {}):
        request, cookie = start()
        code = str(uuid4())
        grants[code] = (request, overrides)
        callback = CALLBACK + "?" + urlencode({"state": request["state"], "code": code})
        wrong_browser = server.request(callback, expected=303)[1]
        assert wrong_browser["Location"] == "/?view=security&sso_error=1"
        assert wrong_browser.get_all("Set-Cookie") is None
        _, headers = server.request(callback, cookie=cookie, expected=303)
        if overrides:
            assert headers["Location"] == "/?view=security&sso_error=1"
            assert headers.get_all("Set-Cookie") is None
        else:
            assert headers["Location"] == "/"
            session, = [item.split(";", 1)[0] for item in headers.get_all("Set-Cookie") if item.startswith("dd_session=")]
            assert server.request(callback, cookie=cookie, expected=303)[1]["Location"] == "/?view=security&sso_error=1"
    assert server.request("/api/session", cookie=session)[0]["name"] == "Entra Owner"
    server.request(f"/api/companies/{company}/team", cookie=session)
    server.request(f"/api/companies/{other}/team", cookie=session, expected=403)
    server.request(f"/api/projects/{project}/overview", cookie=session)
    server.request(f"/api/projects/{project}/cases", cookie=session)
    server.sql(f"SELECT ductdelta.unlink_company_entra('{company}','{actor}')")
    server.request("/api/session", cookie=session, expected=401)
    print("PASS: Entra OIDC with PKCE, signed tenant/audience/nonce checks, one-use browser state, explicit work-account links and company MFA")


def browser_check(server, messages):
    _, company, _, _ = setup_company(server, messages)
    subprocess.run(["node", "scripts/check_company_sign_in.mjs"], cwd=ROOT, check=True, env={
        **os.environ, "DD_ENTRA_ORIGIN": server.origin, "DD_ENTRA_COMPANY": company,
    })


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", action="store_true")
    browser = parser.parse_args().browser
    frontend = ROOT / "frontend/.output/public" if browser else None
    if browser and (not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE") or not (frontend / "index.html").is_file()):
        raise SystemExit("Build the frontend and set DUCTDELTA_PLAYWRIGHT_MODULE before running the browser check.")

    with entra_provider() as (origin, grants), provider() as (url, messages, release), workspace(frontend=frontend, service_env={
        **mail_environment(url), "DUCTDELTA_EMAIL_SIGN_IN": "1",
        "DUCTDELTA_ENTRA_CLIENT_ID": CLIENT, "DUCTDELTA_ENTRA_CLIENT_SECRET": SECRET,
        "DUCTDELTA_ENTRA_TEST_AUTHORITY": origin,
    }) as server:
        release.set()
        if browser:
            browser_check(server, messages)
        else:
            check(server, messages, origin, grants)
