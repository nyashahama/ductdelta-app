#!/usr/bin/env python3
"""Verify the case issuer and mobile recipient flows in Chrome."""

import os
import subprocess

from check_issued_notices import seed_notice
from check_workspace import PROJECT, REPORTER, ROOT, grant_demo_capabilities, workspace

if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
    raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the absolute path to playwright/index.mjs.")

frontend = ROOT / "frontend/.output/public"
if not (frontend / "workspace/index.html").is_file():
    raise SystemExit("Build the Nuxt frontend before running the browser check.")

with workspace(frontend=frontend) as server:
    grant_demo_capabilities(server)
    cookie = server.sign_in(server.key(REPORTER, "Site reporter"))
    detail, _ = seed_notice(server, cookie)
    subprocess.run(
        ["node", "scripts/check_issued_notice_browser.mjs"],
        env={**os.environ, "DD_NOTICE_ORIGIN": server.origin, "DD_NOTICE_PROJECT": PROJECT,
             "DD_NOTICE_CASE": detail.rsplit("/", 1)[-1], "DD_NOTICE_SESSION": cookie.split("=", 1)[1]},
        cwd=ROOT, check=True,
    )
