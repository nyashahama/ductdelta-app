#!/usr/bin/env python3
"""Verify company invitations and live access changes through the HTTP API."""

from concurrent.futures import ThreadPoolExecutor
import secrets
import uuid

from check_workspace import workspace


def cookie(headers):
    return headers["Set-Cookie"].split(";", 1)[0]


def company(server, name):
    result, headers = server.request(
        "/api/companies", "POST", {"company": name, "name": f"{name} owner", "recovery_key": secrets.token_hex(32)}, expected=201,
    )
    return f"/api/companies/{result['id']}", cookie(headers)


def invite(server, path, admin, name, role="member"):
    result, headers = server.request(
        f"{path}/invitations", "POST", {"name": name, "role": role}, admin, expected=201,
    )
    assert headers["Cache-Control"] == "no-store"
    return result


def accept(server, invite_token, existing=None, expected=201):
    return server.request(
        "/api/invitations/accept", "POST",
        {"token": invite_token, "use_current_account": existing is not None,
         "recovery_key": secrets.token_hex(32) if existing is None else None}, existing,
        expected=expected,
    )


def expired_invitation(server, path, admin):
    invitation = invite(server, path, admin, "Expired teammate")
    server.sql(
        "UPDATE ductdelta.company_invitation SET expires_at = clock_timestamp() - interval '1 day' "
        f"WHERE id = '{invitation['id']}'"
    )
    return invitation


def assert_expired_invitation_unused(server, invitation):
    assert server.sql(
        "SELECT accepted_by IS NULL FROM ductdelta.company_invitation "
        f"WHERE id = '{invitation['id']}'"
    ) == "t"
    assert server.sql(
        "SELECT count(*) FROM ductdelta.web_access_key WHERE display_name = 'Expired teammate'"
    ) == "0"


def verify(server):
    path, admin = company(server, "Basin Mechanical")
    unrelated, outsider = company(server, "Other Company")
    project = server.request(
        f"{path}/projects", "POST", {"name": "Plantroom", "operation_id": str(uuid.uuid4())},
        admin, expected=201,
    )[0]["id"]
    overview_path = f"/api/projects/{project}/overview"
    owner = server.request(f"{path}/team", cookie=admin)[0]["actor_id"]
    server.request(f"{path}/members/{owner}", "DELETE", cookie=admin, expected=409)
    server.request(f"{path}/members/{owner}", "PUT", {"role": "member"}, admin, expected=409)
    server.request(f"{path}/team", cookie=outsider, expected=404)
    server.request(f"{path}/invitations", "POST", {"name": "No access", "role": "admin"}, outsider, expected=404)

    revoked = invite(server, path, admin, "Cancelled")
    assert "token" not in server.request(f"{path}/team", cookie=admin)[0]["invitations"][0]
    server.request(f"{path}/invitations/{revoked['id']}", "DELETE", cookie=admin, expected=204)
    accept(server, revoked["token"], expected=404)

    expired = expired_invitation(server, path, admin)
    actor_count = server.sql("SELECT count(*) FROM ductdelta.actor")
    response, headers = accept(server, expired["token"], expected=404)
    assert response == {"message": "This record is unavailable."}
    assert headers.get("Set-Cookie") is None
    accept(server, expired["token"], existing=outsider, expected=404)
    assert_expired_invitation_unused(server, expired)
    assert server.sql("SELECT count(*) FROM ductdelta.actor") == actor_count
    assert len(server.request(f"{path}/team", cookie=admin)[0]["members"]) == 1

    member_invite = invite(server, path, admin, "Site teammate")
    with ThreadPoolExecutor(max_workers=2) as workers:
        def redeem():
            try:
                return accept(server, member_invite["token"])
            except AssertionError as error:
                assert error.args[0][2] == 404, error
                return None
        responses = list(workers.map(lambda _: redeem(), range(2)))
    assert sum(response is not None for response in responses) == 1
    created, headers = next(response for response in responses if response is not None)
    member = cookie(headers)
    assert server.sign_in(created["key"])
    team = server.request(f"{path}/team", cookie=admin)[0]
    actor = next(row["id"] for row in team["members"] if row["name"] == "Site teammate")
    assert not team["invitations"]
    assert server.request("/api/projects", cookie=member)[0] == []
    server.request(f"{path}/team", cookie=member, expected=404)
    server.request(overview_path, cookie=member, expected=404)

    endpoint = f"{path}/projects/{project}/members/{actor}"
    access = {"permission": "capture", "capabilities": ["finance"]}
    server.request(endpoint, "PUT", access, member, expected=404)
    server.request(endpoint, "PUT", {**access, "capabilities": ["unsupported"]}, admin, expected=422)
    server.request(endpoint, "PUT", access, admin, expected=204)
    assert server.request("/api/projects", cookie=member)[0][0]["permission"] == "capture"
    assert server.request(overview_path, cookie=member)[0]["financial"] is not None
    observation_path = f"/api/projects/{project}/observations"
    observation = {"operation_id": str(uuid.uuid4()), "note": "A beam blocks the duct route."}
    saved = server.request(observation_path, "POST", observation, member)[0]
    server.request(endpoint, "PUT", {"permission": "read", "capabilities": []}, admin, expected=204)
    assert server.request("/api/projects", cookie=member)[0][0]["permission"] == "read"
    assert server.request(overview_path, cookie=member)[0]["financial"] is None
    server.request(observation_path, "POST", observation, member, expected=404)
    assert server.request(f"{observation_path}/{saved['id']}", cookie=member)[0]["actor_id"] == actor
    server.request(endpoint, "PUT", {"permission": None, "capabilities": []}, admin, expected=204)
    server.request(overview_path, cookie=member, expected=404)
    server.request(endpoint, "PUT", access, admin, expected=204)

    other_project = server.request(
        f"{path}/projects", "POST", {"name": "Roof", "operation_id": str(uuid.uuid4())},
        admin, expected=201,
    )[0]["id"]
    other_endpoint = f"{path}/projects/{other_project}/members/{actor}"
    other_overview = f"/api/projects/{other_project}/overview"
    server.request(other_endpoint, "PUT", {"permission": "read", "capabilities": ["finance"]}, admin, expected=204)

    cases = f"/api/projects/{project}/cases"
    case = server.request(cases, "POST", {
        "operation_id": str(uuid.uuid4()),
        "title": "Plantroom duct route",
        "observation_id": saved["id"],
    }, admin)[0]
    detail = f"{cases}/{case['id']}"
    server.request(f"{detail}/actions", "POST", {
        "operation_id": str(uuid.uuid4()),
        "kind": "instruction",
        "data": {"reference": "Start", "agreement": "M-1", "scope": "Verify route"},
    }, admin)
    actions = {
        "direction": ("instruction", {"agreement": "M-1", "scope": "Move elbow"}),
        "commercial": ("quote", {"lines": [{"description": "Move elbow", "amount": "1000"}]}),
        "finance": ("receipt", {"amount": "1000"}),
    }
    for index, dropped in enumerate(actions, 1):
        retained = sorted(actions.keys() - {dropped})
        server.request(endpoint, "PUT", {"permission": "capture", "capabilities": retained}, admin, expected=204)
        assert server.request(detail, cookie=member)[0]["capabilities"] == retained
        assert server.request(other_overview, cookie=member)[0]["financial"] is not None
        for capability, (kind, data) in actions.items():
            server.request(f"{detail}/actions", "POST", {
                "operation_id": str(uuid.uuid4()),
                "kind": kind,
                "data": {**data, "reference": f"{kind}-{index}"},
            }, member, expected=404 if capability == dropped else 200)

    second = invite(server, unrelated, outsider, "Site teammate")
    assert accept(server, second["token"], existing=member)[0] == {"id": unrelated.split("/")[-1]}
    assert len(server.request("/api/companies", cookie=member)[0]) == 2
    server.request(f"{path}/members/{actor}", "PUT", {"role": "admin"}, admin, expected=204)
    server.request(f"{path}/team", cookie=member)
    pending = invite(server, path, member, "Pending from former admin")
    server.request(f"{path}/members/{actor}", "PUT", {"role": "member"}, admin, expected=204)
    accept(server, pending["token"], expected=404)
    server.request(f"{path}/team", cookie=member, expected=404)
    server.request(overview_path, cookie=member)
    server.request(f"{path}/members/{actor}", "PUT", {"role": "admin"}, admin, expected=204)
    pending = invite(server, path, member, "Pending from removed admin")
    server.request(f"{path}/members/{actor}", "DELETE", cookie=admin, expected=204)
    accept(server, pending["token"], expected=404)
    server.request(overview_path, cookie=member, expected=404)
    server.request(other_overview, cookie=member, expected=404)
    assert [row["id"] for row in server.request("/api/companies", cookie=member)[0]] == [unrelated.split("/")[-1]]
    assert server.request(f"{observation_path}/{saved['id']}", cookie=admin)[0]["actor_id"] == actor

    administrator_invite = invite(server, path, admin, "Second administrator", "admin")
    _, headers = accept(server, administrator_invite["token"])
    second_admin = cookie(headers)
    second_actor = server.request(f"{path}/team", cookie=second_admin)[0]["actor_id"]

    def demote_self(administrator):
        current_cookie, current_actor = administrator
        try:
            server.request(f"{path}/members/{current_actor}", "PUT", {"role": "member"}, current_cookie, expected=204)
        except AssertionError as error:
            assert error.args[0][2] == 409, error
            return current_cookie
        return None

    with ThreadPoolExecutor(max_workers=2) as workers:
        outcomes = list(workers.map(demote_self, [(admin, owner), (second_admin, second_actor)]))
    (remaining_admin,) = [session for session in outcomes if session is not None]
    members = server.request(f"{path}/team", cookie=remaining_admin)[0]["members"]
    assert sorted(member["role"] for member in members) == ["admin", "member"]
    print("PASS: expired and single-use invitations, administrator demotion and races, independent project grants and tenant-scoped removal")


if __name__ == "__main__":
    with workspace(seed=False) as server:
        verify(server)
