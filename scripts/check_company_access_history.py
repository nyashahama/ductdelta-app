#!/usr/bin/env python3
"""Verify invitation defaults and attributable access changes on PostgreSQL 18."""

from datetime import datetime, timedelta
import hashlib
import json
import secrets
import subprocess
import uuid

from check_company_team import accept, company, invite
from check_postgres import BIN, connection
from check_workspace import workspace


legacy_token = secrets.token_hex(32)
legacy = {}


def seed_legacy_invitation(server):
    digests = [secrets.token_hex(32) for _ in range(3)]
    session = digests[2]
    session_digest = hashlib.sha256(session.encode()).hexdigest()
    legacy["company"] = server.sql(
        f"SELECT ductdelta.web_register_company('Legacy company', 'Legacy admin', "
        f"decode('{digests[0]}', 'hex'), decode('{digests[1]}', 'hex'), decode('{session_digest}', 'hex'));"
    )
    digest = hashlib.sha256(legacy_token.encode()).hexdigest()
    legacy.update(json.loads(server.sql(
        f"SELECT ductdelta.web_invite(decode('{session_digest}', 'hex'), '{legacy['company']}', "
        f"'Legacy recipient', 'member', decode('{digest}', 'hex'));"
    )))
    legacy["session"] = session


def verify(server):
    path, admin = company(server, "Test Mechanical")
    other, outsider = company(server, "Unrelated")
    settings = path + "/invitation-lifetime"
    history = path + "/access-history"

    def events():
        page, headers = server.request(history, cookie=admin)
        assert headers["Cache-Control"] == "no-store"
        return page["events"]

    assert server.request(settings, cookie=admin)[0] == {"days": 7}
    assert events() == []
    for endpoint in (settings, history):
        server.request(endpoint, expected=401)
        server.request(endpoint, cookie=outsider, expected=404)
    server.request(settings, "PUT", {"days": 1}, outsider, expected=404)
    server.request(settings, "PUT", {"days": 1}, admin, origin="https://invalid.example", expected=403)
    for invalid in (0, 15):
        server.request(settings, "PUT", {"days": invalid}, admin, expected=422)
    assert events() == []

    owner = server.request(path + "/team", cookie=admin)[0]["actor_id"]
    server.request(path + "/members/" + owner, "PUT", {"role": "member"}, admin, expected=409)
    assert events() == []
    old_link = invite(server, path, admin, "Already issued")
    assert server.request(settings, "PUT", {"days": 2}, admin)[0] == {"days": 2}
    assert server.request(settings, "PUT", {"days": 2}, admin)[0] == {"days": 2}
    assert server.request(other + "/invitation-lifetime", cookie=outsider)[0] == {"days": 7}
    member_link = invite(server, path, admin, "Project teammate")
    new_expiry = datetime.fromisoformat(member_link["expires_at"])
    previous_expiry = datetime.fromisoformat(old_link["expires_at"])
    assert timedelta(days=4, hours=23) < previous_expiry - new_expiry < timedelta(days=5, hours=1)
    team = server.request(path + "/team", cookie=admin)[0]
    assert next(row["expires_at"] for row in team["invitations"] if row["id"] == old_link["id"]) == old_link["expires_at"]
    server.request(path + "/invitations/" + old_link["id"], "DELETE", cookie=admin, expected=204)
    server.request(path + "/invitations/" + old_link["id"], "DELETE", cookie=admin, expected=204)
    accept(server, old_link["token"], expected=404)

    _, headers = accept(server, member_link["token"])
    member = headers["Set-Cookie"].split(";", 1)[0]
    team = server.request(path + "/team", cookie=admin)[0]
    member_id = next(row["id"] for row in team["members"] if row["name"] == "Project teammate")
    for endpoint in (settings, history):
        server.request(endpoint, cookie=member, expected=404)
    server.request(settings, "PUT", {"days": 1}, member, expected=404)
    accept(server, member_link["token"], expected=404)

    project_setup = {"name": "Plantroom", "operation_id": str(uuid.uuid4())}
    project_id = server.request(path + "/projects", "POST", project_setup, admin, expected=201)[0]["id"]
    assert server.request(path + "/projects", "POST", project_setup, admin, expected=201)[0]["id"] == project_id
    initial_grant = events()[0]
    assert initial_grant["kind"] == "project_access_changed" and initial_grant["target_id"] == owner
    project_access = f"{path}/projects/{project_id}/members/{member_id}"
    grant = {"permission": "capture", "capabilities": ["finance", "commercial"]}
    server.request(project_access, "PUT", grant, admin, expected=204)
    server.request(project_access, "PUT", {**grant, "capabilities": ["commercial", "finance"]}, admin, expected=204)
    server.request(project_access, "PUT", {**grant, "capabilities": ["bad"]}, admin, expected=422)
    server.request(project_access, "PUT", {"permission": None, "capabilities": []}, admin, expected=204)

    member_path = path + "/members/" + member_id
    server.request(member_path, "PUT", {"role": "admin"}, admin, expected=204)
    automatic = invite(server, path, member, "Pending from former admin")
    server.request(member_path, "PUT", {"role": "member"}, admin, expected=204)
    accept(server, automatic["token"], expected=404)
    server.request(project_access, "PUT", {"permission": "read", "capabilities": []}, admin, expected=204)
    server.request(member_path, "DELETE", cookie=admin, expected=204)

    expected = [
        ("invitation_created", owner, old_link["id"], None, {"role": "member", "expires_at": old_link["expires_at"]}),
        ("invitation_lifetime_changed", owner, None, {"days": 7}, {"days": 2}),
        ("invitation_created", owner, member_link["id"], None, {"role": "member", "expires_at": member_link["expires_at"]}),
        ("invitation_revoked", owner, old_link["id"], {"status": "pending"}, {"status": "revoked"}),
        ("invitation_accepted", member_id, member_link["id"], {"status": "pending"}, {"status": "accepted", "role": "member"}),
        ("project_access_changed", owner, owner, None, {"permission": "capture", "capabilities": ["commercial", "direction", "finance"]}),
        ("project_access_changed", owner, member_id, None, {"permission": "capture", "capabilities": ["commercial", "finance"]}),
        ("project_access_changed", owner, member_id, {"permission": "capture", "capabilities": ["commercial", "finance"]}, None),
        ("company_role_changed", owner, member_id, {"role": "member"}, {"role": "admin"}),
        ("invitation_created", member_id, automatic["id"], None, {"role": "member", "expires_at": automatic["expires_at"]}),
        ("invitation_revoked", owner, automatic["id"], {"status": "pending"}, {"status": "revoked", "reason": "inviter_lost_admin"}),
        ("company_role_changed", owner, member_id, {"role": "admin"}, {"role": "member"}),
        ("project_access_changed", owner, member_id, None, {"permission": "read", "capabilities": []}),
        ("project_access_changed", owner, member_id, {"permission": "read", "capabilities": []}, None),
        ("company_member_removed", owner, member_id, {"role": "member"}, None),
    ]
    activity = events()
    assert [
        (row["kind"], row["actor_id"], row["target_id"], row["before"], row["after"])
        for row in reversed(activity)
    ] == expected, activity
    assert activity[0]["actor_name"] == "Test Mechanical owner"
    assert activity[0]["target_name"] == "Project teammate"
    project_changes = [event for event in activity if event["kind"] == "project_access_changed"]
    assert all(event["project_id"] == project_id and event["project_name"] == "Plantroom"
               for event in project_changes)
    assert all(datetime.fromisoformat(row["recorded_at"]).tzinfo for row in activity)
    assert all(link["token"] not in json.dumps(activity) for link in (old_link, member_link, automatic))
    assert "token_digest" not in json.dumps(activity)
    assert server.request(other + "/access-history", cookie=outsider)[0] == {"events": [], "next_before": None}

    for index in range(40):
        invite(server, path, admin, f"Pagination test {index}")
    page = server.request(history, cookie=admin)[0]
    assert len(page["events"]) == 50 and page["next_before"] == page["events"][-1]["id"]
    server.request(f"{other}/access-history?before={page['next_before']}", cookie=outsider, expected=404)
    next_page = server.request(f"{history}?before={page['next_before']}", cookie=admin)[0]
    assert len(next_page["events"]) == len(expected) + 40 - 50 and next_page["next_before"] is None
    assert set(row["id"] for row in page["events"]).isdisjoint(row["id"] for row in next_page["events"])

    email = "never-show@example.test"
    private_label = invite(server, path, admin, email)
    latest = events()[0]
    assert latest["target_id"] == private_label["id"] and latest["target_name"] is None
    assert email not in json.dumps(events())

    assert server.request(other + "/invitation-lifetime", "PUT", {"days": 14}, outsider)[0] == {"days": 14}
    assert server.request(other + "/invitation-lifetime", "PUT", {"days": 1}, outsider)[0] == {"days": 1}

    legacy_path = f"/api/companies/{legacy['company']}"
    legacy_cookie = f"dd_session={legacy['session']}"
    assert server.request(legacy_path + "/team", cookie=legacy_cookie)[0]["invitations"][0]["expires_at"] == legacy["expires_at"]
    assert server.request(legacy_path + "/access-history", cookie=legacy_cookie)[0]["events"] == []
    accept(server, legacy_token)
    legacy_events = server.request(legacy_path + "/access-history", cookie=legacy_cookie)[0]["events"]
    assert [(row["kind"], row["target_id"]) for row in legacy_events] == [("invitation_accepted", legacy["id"])]

    denied = subprocess.run(
        [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", connection(server.database_socket, "dd_web")],
        input="DELETE FROM ductdelta.company_access_event;", text=True, capture_output=True,
        env=server.environment, timeout=10,
    )
    assert denied.returncode and "permission denied" in denied.stderr
    print("PASS: default lifetime, preserved pre-upgrade link, admin isolation, attributable audit and pagination")


if __name__ == "__main__":
    with workspace(seed=False, before_migration=("0014_company_access_history.sql", seed_legacy_invitation)) as server:
        verify(server)
