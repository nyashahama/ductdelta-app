#!/usr/bin/env python3
"""Run the browser setup check using an installed Playwright module and Chrome."""

import os
import subprocess

from check_workspace import ROOT, workspace

if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
    raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the absolute path to playwright/index.mjs.")
if not (ROOT / "frontend/.output/public/index.html").is_file():
    raise SystemExit("Build the Nuxt frontend before running the browser check.")

with workspace(frontend=ROOT / "frontend/.output/public", seed=False) as server:
    subprocess.run(
        ["node", "scripts/check_browser_setup.mjs"],
        env={**os.environ, "DD_SETUP_ORIGIN": server.origin},
        cwd=ROOT, check=True,
    )
