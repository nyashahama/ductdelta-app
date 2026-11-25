#!/usr/bin/env python3
"""Exercise the prebuilt Nuxt workspace from the Rust HTTP entry point."""

import argparse
import base64
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import urljoin

from check_workspace import ROOT, workspace

ASSET_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".otf": "font/otf",
    ".avif": "image/avif",
    ".webp": "image/webp",
    ".png": "image/png",
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
        self.style = None
        self.style_hashes = set()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "style":
            self.style = []
        if tag == "script":
            if "src" in attributes:
                self.assets.add(attributes["src"])
            else:
                self.script_type = attributes.get("type", "").split(";", 1)[0].strip().lower()
                self.script = []
        if tag == "link" and attributes.get("rel") in ("stylesheet", "modulepreload", "preload", "icon"):
            asset = attributes.get("href", "")
            if asset.startswith(("/_nuxt/", "/_next/", "/product/")):
                self.assets.add(asset)
        if tag == "img":
            self.assets.add(attributes["src"])
        if tag in ("img", "source"):
            for source in attributes.get("srcset", "").split(","):
                if source.strip():
                    self.assets.add(source.split()[0])

    def handle_endtag(self, tag):
        if tag == "style" and self.style is not None:
            style = "".join(self.style).replace("\r\n", "\n").replace("\r", "\n")
            if style.strip():
                self.style_hashes.add(base64.b64encode(hashlib.sha256(style.encode()).digest()).decode())
            self.style = None
        if tag == "script" and self.script_type is not None:
            script = "".join(self.script).replace("\r\n", "\n").replace("\r", "\n")
            if script.strip():
                digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
                self.hashes.add(digest)
                if self.script_type in SCRIPT_TYPES:
                    self.executable_hashes.add(digest)
            self.script_type = None

    def handle_data(self, data):
        if self.style is not None:
            self.style.append(data)
        if self.script_type is not None:
            self.script.append(data)


def verify(server, public_dir):
    landing, _ = server.request("/")
    assert b"Every change." in landing, "The home URL must serve the approved landing page"
    assert server.request("/?project=old&view=cases", expected=302)[1]["Location"] == "/workspace/?project=old&view=cases"
    assert server.request("/product/?utm_campaign=old", expected=308)[1]["Location"] == "/?utm_campaign=old"
    assert server.request("/workspace", expected=308)[1]["Location"] == "/workspace/"
    body, headers = server.request("/workspace/")
    assert body == (public_dir / "workspace/index.html").read_bytes()
    assert headers["Content-Type"] == "text/html; charset=utf-8"
    assert headers["Cache-Control"] == "no-store"
    policy = headers["Content-Security-Policy"]
    assert "frame-ancestors 'none'" in policy and "script-src 'self'" in policy
    assert "'unsafe-eval'" not in policy

    shell = Shell()
    shell.feed(body.decode())
    shell.close()
    directives = dict(directive.strip().split(" ", 1) for directive in policy.split(";"))
    assert directives.pop("style-src-attr") == "'unsafe-inline'"
    assert all("'unsafe-inline'" not in value for value in directives.values())
    hashes = set(re.findall(r"'sha256-([^']+)'", directives["script-src"]))
    receipt = set((public_dir / "script-hashes.txt").read_text().splitlines())
    assert hashes == receipt
    assert shell.executable_hashes and shell.executable_hashes <= hashes <= shell.hashes
    style_hashes = set(re.findall(r"'sha256-([^']+)'", directives["style-src"]))
    assert style_hashes == set((public_dir / "style-hashes.txt").read_text().splitlines())
    assert style_hashes and style_hashes == shell.style_hashes

    files = {}
    for asset in (public_dir / "_nuxt").rglob("*"):
        if asset.is_file() and not asset.is_symlink() and asset.suffix in ASSET_TYPES:
            files[f"/{asset.relative_to(public_dir).as_posix()}"] = asset
    assert shell.assets and shell.assets <= files.keys(), shell.assets - files.keys()
    assert any(file.suffix == ".js" for file in files.values())
    assert any(file.suffix == ".css" for file in files.values())
    font_urls = set()
    for stylesheet, asset in files.items():
        if asset.suffix != ".css":
            continue
        for rule in re.findall(r"@font-face\s*\{([^}]+)\}", asset.read_text()):
            if re.search(r"font-family:\s*['\"]?Public Sans(?:['\"]|;)", rule):
                paths = re.findall(r"url\(['\"]?([^'\"()]+\.woff2)['\"]?\)", rule)
                font_urls.update(urljoin(stylesheet, path) for path in paths)
    assert font_urls and font_urls <= files.keys(), "Public Sans must ship with the workspace"
    assert "/_nuxt/fonts/public-sans-2.001/public-sans-normal-latin.woff2" in font_urls
    for url, asset in files.items():
        asset_bytes, asset_headers = server.request(url)
        assert asset_bytes == asset.read_bytes(), url
        assert asset_headers["Content-Type"] == ASSET_TYPES[asset.suffix], url
        assert "immutable" in asset_headers["Cache-Control"], url
        assert asset_headers["X-Content-Type-Options"] == "nosniff", url
        if url in font_urls:
            assert asset_headers["Access-Control-Allow-Origin"] == "*", url
        else:
            assert "Access-Control-Allow-Origin" not in asset_headers, url

    server.request("/_nuxt/unknown.js", expected=404)
    server.request("/_nuxt/%2e%2e/index.html", expected=404)
    server.request("/_nuxt/script-hashes.txt", expected=404)
    server.request("/script-hashes.txt", expected=404)
    server.request("/style-hashes.txt", expected=404)
    server.request("/assets/workspace.js", expected=404)
    server.request("/api/projects", expected=401)
    print("PASS: Nuxt shell, exact bootstrap receipt, typed immutable assets and protected same-origin API")

    verify_marketing(server, public_dir / "marketing", policy)


def verify_marketing(server, marketing_dir, workspace_policy):
    pages = {
        "/": "index.html",
        "/product/workflow/": "product/workflow/index.html",
        "/product/example/": "product/example/index.html",
        "/product/faq/": "product/faq/index.html",
    }
    references = set()
    for url, file in pages.items():
        page, headers = server.request(url)
        assert page == (marketing_dir / file).read_bytes(), url
        assert b'href="/workspace/"' in page
        assert f'rel="canonical" href="https://ductdelta.com{url}"'.encode() in page
        assert headers["Content-Type"] == "text/html; charset=utf-8"
        assert headers["Cache-Control"] == "no-store"
        assert headers["X-Robots-Tag"] == "noindex, follow"
        if url != "/":
            alias = url.rstrip("/") + "?utm_source=release&ref=a%2Fb"
            assert server.request(alias, expected=308)[1]["Location"] == url + "?utm_source=release&ref=a%2Fb"
        policy = headers["Content-Security-Policy"]
        assert policy != workspace_policy
        directives = dict(directive.strip().split(" ", 1) for directive in policy.split(";"))
        assert directives["default-src"] == "'self'"
        assert directives["frame-ancestors"] == "'none'"
        assert directives["form-action"] == "'none'"
        assert "'unsafe-inline'" not in directives["script-src"]
        assert "'unsafe-eval'" not in directives["script-src"]
        shell = Shell()
        shell.feed(page.decode())
        shell.close()
        assert shell.executable_hashes == set(re.findall(r"'sha256-([^']+)'", directives["script-src"]))
        assert shell.style_hashes == set(re.findall(r"'sha256-([^']+)'", directives["style-src"]))
        references.update(shell.assets)

    assert references
    for url in references:
        asset = marketing_dir / url.removeprefix("/")
        body, headers = server.request(url)
        assert body == asset.read_bytes(), url
        assert headers["Content-Type"] == ASSET_TYPES[asset.suffix], url
        assert headers["X-Content-Type-Options"] == "nosniff", url
        if url.startswith("/_next/static/"):
            assert "immutable" in headers["Cache-Control"], url

    licenses, headers = server.request("/product/licenses.txt")
    assert licenses == (marketing_dir / "product/licenses.txt").read_bytes()
    assert headers["Content-Type"] == "text/plain; charset=utf-8"
    assert server.request("/product/healthz", expected=204)[0] == b""
    assert server.request("/product/sitemap.xml", expected=308)[1]["Location"] == "/sitemap.xml"
    sitemap, headers = server.request("/sitemap.xml")
    assert headers["Content-Type"] == "application/xml; charset=utf-8"
    assert re.findall(rb"<loc>([^<]+)</loc>", sitemap) == [
        f"https://ductdelta.com{url}".encode() for url in pages
    ]
    assert b"https://ductdelta.com/sitemap.xml" in server.request("/robots.txt")[0]
    assert server.request("/?utm_source=release")[0] == server.request("/")[0]
    page, headers = server.request("/product/unknown", expected=404)
    assert headers["X-Robots-Tag"] == "noindex, follow"
    assert b"This page moved or no longer exists" in page
    server.request("/_next/static/unknown.js", expected=404)
    server.request("/product/_astro/unknown.js", expected=404)
    server.request("/product/_astro/%2e%2e/index.html", expected=404)
    server.request("/product/script-hashes.txt", expected=404)
    server.request("/product/faq/index.html.csp", expected=404)
    print("PASS: marketing pages, old links, canonical URLs, script hashes and typed assets")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, default=ROOT / "frontend/.output/public")
    args = parser.parse_args()
    public_dir = args.dist.resolve()
    with workspace(frontend=public_dir) as server:
        verify(server, public_dir)
