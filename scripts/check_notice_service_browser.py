#!/usr/bin/env python3
"""Exercise notice issue, dispatch, acknowledgement and recipient download in Chrome."""

import os
import subprocess

from check_workspace import PROJECT, REPORTER, ROOT, VIEWER, grant_demo_capabilities, workspace

frontend = ROOT / "frontend/.output/public"
if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
    raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the absolute path to playwright/index.mjs.")
if not (frontend / "index.html").is_file():
    raise SystemExit("Build the Nuxt frontend before running the browser check.")

configured = (ROOT / "migrations/0018_notice_rules.sql").is_file()
with workspace(frontend=frontend) as server:
    if configured:
        from check_notice_rules import prepare

        prepare(server)
        server.sql(
            f"DELETE FROM ductdelta.project_workflow_grant WHERE project_id = '{PROJECT}' "
            f"AND actor_id = '{VIEWER}' AND capability = 'direction'"
        )
    else:
        grant_demo_capabilities(server)
    subprocess.run(
        ["node", "scripts/check_notice_service_browser.mjs"],
        env={**os.environ, "DD_SERVICE_ORIGIN": server.origin, "DD_SERVICE_PROJECT": PROJECT,
             "DD_SERVICE_CONFIGURED": "1" if configured else "0",
             "DD_SERVICE_ADMIN": server.key(REPORTER, "Site administrator"),
             "DD_SERVICE_VIEWER": server.key(VIEWER, "Project viewer")},
        cwd=ROOT, check=True,
    )
