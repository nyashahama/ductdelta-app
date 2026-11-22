#!/usr/bin/env python3
"""Exercise private operator alerts through the real application and a loopback provider."""

from collections import Counter
import subprocess
import time
from uuid import uuid4

from check_company_team import accept, company, invite
from check_invitation_email import mail_environment, provider
from check_workspace import workspace


def verify(server, requests, release):
    company(server, "Before alerts were enabled")
    assert not requests
    server.sql("""
        INSERT INTO ductdelta.activity_email_settings (recipient, sender)
        VALUES ('first@example.test', 'DuctDelta <activity@example.test>')
    """)
    try:
        server.sql("SELECT recipient FROM ductdelta.activity_email_settings", actor="dd_web")
    except subprocess.CalledProcessError as error:
        assert "permission denied" in error.stderr
    else:
        raise AssertionError("The web role can read operator settings directly")

    company_path, admin = company(server, "Private Company Name")
    release.set()
    invitation = invite(server, company_path, admin, "Private Teammate Name")
    accept(server, invitation["token"])
    accept(server, invitation["token"], expected=404)

    project_draft = {"name": "Private Project Name", "operation_id": str(uuid4())}
    projects = f"{company_path}/projects"
    server.request(projects, "POST", project_draft, expected=401)
    project = server.request(projects, "POST", project_draft, admin, expected=201)[0]
    assert server.request(projects, "POST", project_draft, admin, expected=201)[0] == project
    cases = f"/api/projects/{project['id']}/cases"
    case_draft = {"title": "Private Change Name", "operation_id": str(uuid4())}
    case = server.request(cases, "POST", case_draft, admin)[0]
    assert server.request(cases, "POST", case_draft, admin)[0] == case
    instruction = {"kind": "instruction", "operation_id": str(uuid4()), "data": {
        "reference": "Private instruction reference",
        "agreement": "Private agreement",
        "scope": "Private site instruction",
    }}
    action = f"{cases}/{case['id']}/actions"
    event = server.request(action, "POST", instruction, admin)[0]
    assert server.request(action, "POST", instruction, admin)[0] == event

    for _ in range(220):
        if server.sql("SELECT count(*) FROM ductdelta.activity_email WHERE accepted_id IS NOT NULL") == "5":
            break
        time.sleep(0.05)
    else:
        raise AssertionError("The five expected activity alerts did not settle")

    counts = Counter(key for key, _ in requests)
    assert len(requests) == 6 and sorted(counts.values()) == [1, 1, 1, 1, 2]
    retry = [payload for key, payload in requests if counts[key] == 2]
    assert retry[0] == retry[1]
    assert {message["subject"] for _, message in requests} == {
        "DuctDelta: new company signup", "DuctDelta: invitation accepted",
        "DuctDelta: new project", "DuctDelta: change case opened",
        "DuctDelta: site instruction recorded",
    }
    for key, message in requests:
        assert key.startswith("activity/")
        assert message["from"] == "DuctDelta <activity@example.test>"
        assert message["to"] == ["first@example.test"]
        assert " UTC" in message["text"]
        assert " UTC" in message.get("html", ""), "The activity layout must include the UTC timestamp"
        assert "DuctDelta" in message["html"] and "<h1" in message["html"]
        assert "href=" not in message["html"] and "reply_to" not in message
        assert "Private " not in str(message) and "Before alerts" not in str(message)
        assert invitation["token"] not in str(message)
    server.sql("DELETE FROM ductdelta.activity_email_settings")
    company(server, "After alerts were disabled")
    assert server.sql("SELECT count(*) FROM ductdelta.activity_email") == "5"
    print("PASS: operator alerts for signup, acceptance, project and case activity, stable retries and private payloads")


if __name__ == "__main__":
    with provider() as (url, requests, release), workspace(
        seed=False, service_env=mail_environment(url),
    ) as server:
        verify(server, requests, release)
