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

    second = invite(server, unrelated, outsider, "Site teammate")
    assert accept(server, second["token"], existing=member)[0] == {"id": unrelated.split("/")[-1]}
    assert len(server.request("/api/companies", cookie=member)[0]) == 2
    server.request(f"{path}/members/{actor}", "PUT", {"role": "admin"}, admin, expected=204)
    server.request(f"{path}/team", cookie=member)
    pending = invite(server, path, member, "Pending from former admin")
    server.request(f"{path}/members/{actor}", "DELETE", cookie=admin, expected=204)
    accept(server, pending["token"], expected=404)
    server.request(overview_path, cookie=member, expected=404)
    assert [row["id"] for row in server.request("/api/companies", cookie=member)[0]] == [unrelated.split("/")[-1]]
    assert server.request(f"{observation_path}/{saved['id']}", cookie=admin)[0]["actor_id"] == actor
    print("PASS: single-use invitation races, role changes, project permissions and tenant-scoped removal")


if __name__ == "__main__":
    with workspace(seed=False) as server:
        verify(server)
