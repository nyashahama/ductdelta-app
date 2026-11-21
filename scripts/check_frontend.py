#!/usr/bin/env python3
"""Exercise the prebuilt Nuxt workspace from the Rust HTTP entry point."""

import argparse
import base64
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re

from check_workspace import ROOT, workspace

ASSET_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".otf": "font/otf",
}
SCRIPT_TYPES = {
    "", "module", "importmap", "speculationrules",
    "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript",
}


class Shell(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = set()
        self.script_type = None
        self.script = []
        self.hashes = set()
        self.executable_hashes = set()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "script":
            if "src" in attributes:
                self.assets.add(attributes["src"])
            else:
                self.script_type = attributes.get("type", "").split(";", 1)[0].strip().lower()
                self.script = []
        if tag == "link" and attributes.get("rel") in ("stylesheet", "modulepreload", "preload"):
            asset = attributes.get("href", "")
            if asset.startswith("/_nuxt/"):
                self.assets.add(asset)

    def handle_endtag(self, tag):
        if tag == "script" and self.script_type is not None:
            script = "".join(self.script).replace("\r\n", "\n").replace("\r", "\n")
            if script.strip():
                digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
                self.hashes.add(digest)
                if self.script_type in SCRIPT_TYPES:
                    self.executable_hashes.add(digest)
            self.script_type = None

    def handle_data(self, data):
        if self.script_type is not None:
            self.script.append(data)


def verify(server, public_dir):
    body, headers = server.request("/")
    assert body == (public_dir / "index.html").read_bytes()
    assert headers["Content-Type"] == "text/html; charset=utf-8"
    assert headers["Cache-Control"] == "no-store"
    policy = headers["Content-Security-Policy"]
    assert "frame-ancestors 'none'" in policy and "script-src 'self'" in policy
    assert "'unsafe-inline'" not in policy and "'unsafe-eval'" not in policy

    shell = Shell()
    shell.feed(body.decode())
    shell.close()
    hashes = set(re.findall(r"'sha256-([^']+)'", policy))
    receipt = set((public_dir / "script-hashes.txt").read_text().splitlines())
    assert hashes == receipt
    assert shell.executable_hashes and shell.executable_hashes <= hashes <= shell.hashes

    files = {}
    for asset in (public_dir / "_nuxt").rglob("*"):
        if asset.is_file() and not asset.is_symlink() and asset.suffix in ASSET_TYPES:
            files[f"/{asset.relative_to(public_dir).as_posix()}"] = asset
    assert shell.assets and shell.assets <= files.keys(), shell.assets - files.keys()
    assert any(file.suffix == ".js" for file in files.values())
    assert any(file.suffix == ".css" for file in files.values())
    for url, asset in files.items():
        asset_bytes, asset_headers = server.request(url)
        assert asset_bytes == asset.read_bytes(), url
        assert asset_headers["Content-Type"] == ASSET_TYPES[asset.suffix], url
        assert "immutable" in asset_headers["Cache-Control"], url
        assert asset_headers["X-Content-Type-Options"] == "nosniff", url

    server.request("/_nuxt/unknown.js", expected=404)
    server.request("/_nuxt/%2e%2e/index.html", expected=404)
    server.request("/_nuxt/script-hashes.txt", expected=404)
    server.request("/script-hashes.txt", expected=404)
    server.request("/assets/workspace.js", expected=404)
    server.request("/api/projects", expected=401)
    print("PASS: Nuxt shell, exact bootstrap receipt, typed immutable assets and protected same-origin API")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, default=ROOT / "frontend/.output/public")
    args = parser.parse_args()
    public_dir = args.dist.resolve()
    with workspace(frontend=public_dir) as server:
        verify(server, public_dir)
