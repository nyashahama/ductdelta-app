#!/usr/bin/env python3
"""Exercise notice setup and entry in Chromium against a disposable PostgreSQL service."""

import os
import subprocess

from check_notice_rules import prepare
from check_workspace import PROJECT, REPORTER, ROOT, VIEWER, workspace

frontend = ROOT / "frontend/.output/public"
if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
    raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the absolute path to playwright/index.mjs.")
if not (frontend / "index.html").is_file():
    raise SystemExit("Build the Nuxt frontend before running the browser check.")

with workspace(frontend=frontend) as server:
    prepare(server)
    subprocess.run(
        ["node", "scripts/check_notice_rules_browser.mjs"],
        env={**os.environ, "DD_RULE_ORIGIN": server.origin, "DD_RULE_PROJECT": PROJECT,
             "DD_RULE_ADMIN": server.key(REPORTER, "Site administrator"),
             "DD_RULE_VIEWER": server.key(VIEWER, "Relief recorder")},
        cwd=ROOT, check=True,
    )
