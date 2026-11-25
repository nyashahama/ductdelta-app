#!/usr/bin/env python3
"""Run the browser setup check using an installed Playwright module and Chrome."""

import os
import subprocess

from check_company_team import assert_expired_invitation_unused, company, expired_invitation, invite
from check_workspace import ROOT, workspace

if not os.environ.get("DUCTDELTA_PLAYWRIGHT_MODULE"):
    raise SystemExit("Set DUCTDELTA_PLAYWRIGHT_MODULE to the absolute path to playwright/index.mjs.")
if not (ROOT / "frontend/.output/public/workspace/index.html").is_file():
    raise SystemExit("Build the Nuxt frontend before running the browser check.")

with workspace(frontend=ROOT / "frontend/.output/public", seed=False) as server:
    second_company, second_admin = company(server, "West Mechanical")
    second_invite = invite(server, second_company, second_admin, "Sam Site", "admin")
    expired = expired_invitation(server, second_company, second_admin)
    subprocess.run(
        ["node", "scripts/check_browser_setup.mjs"],
        env={
            **os.environ,
            "DD_SETUP_ORIGIN": server.origin,
            "DD_SECOND_COMPANY": second_company.rsplit("/", 1)[-1],
            "DD_SECOND_INVITE": second_invite["token"],
            "DD_EXPIRED_INVITE": expired["token"],
        },
        cwd=ROOT, check=True,
    )
    assert_expired_invitation_unused(server, expired)
    members = server.request(f"{second_company}/team", cookie=second_admin)[0]["members"]
    assert sorted((member["name"], member["role"]) for member in members) == [
        ("Sam Site", "admin"),
        ("West Mechanical owner", "admin"),
    ]
