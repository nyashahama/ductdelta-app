#!/usr/bin/env python3
"""Exercise the production TanStack build from the Rust HTTP entry point."""

import hashlib
from html.parser import HTMLParser
import base64

from check_workspace import ROOT, workspace


class Shell(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.inline_scripts = []
        self.in_script = False

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script":
            if "src" in values:
                self.assets.append(values["src"])
            else:
                self.in_script = True
        if tag == "link" and values.get("rel") == "stylesheet":
            self.assets.append(values["href"])

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_script = False

    def handle_data(self, data):
        if self.in_script and data.strip():
            self.inline_scripts.append(data.replace("\r\n", "\n").replace("\r", "\n").encode())


def verify(server):
    body, headers = server.request("/")
    assert b"<title>DuctDelta Workspace</title>" in body
    assert headers["Cache-Control"] == "no-store"
    policy = headers["Content-Security-Policy"]
    assert "frame-ancestors 'none'" in policy and "'unsafe-inline'" not in policy
    shell = Shell()
    shell.feed(body.decode())
    assert shell.inline_scripts and shell.assets
    for script in shell.inline_scripts:
        digest = base64.b64encode(hashlib.sha256(script).digest()).decode()
        assert f"'sha256-{digest}'" in policy
    for asset in shell.assets:
        assert asset.startswith("/assets/") and asset.endswith((".css", ".js"))
        asset_bytes, asset_headers = server.request(asset)
        assert asset_bytes and "immutable" in asset_headers["Cache-Control"]
    server.request("/assets/unknown.js", expected=404)
    server.request("/api/projects", expected=401)
    print("PASS: TanStack shell, hashed bootstrap, static assets and same-origin protected API")


if __name__ == "__main__":
    with workspace(frontend=ROOT / "frontend/dist/client") as server:
        verify(server)
