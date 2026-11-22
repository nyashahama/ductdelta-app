#!/usr/bin/env python3
"""Verify exact notice copies and scoped recipient access over HTTP on PostgreSQL 18."""

from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from pathlib import Path
from secrets import token_hex
import json
import subprocess
from tempfile import TemporaryDirectory
from uuid import uuid4

from check_postgres import BIN, OTHER_PROJECT, connection
from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER, grant_demo_capabilities, workspace


def seed_notice(server, reporter):
    path = f"/api/projects/{PROJECT}/cases"
    case = server.request(path, "POST", {
        "operation_id": str(uuid4()), "title": "Confidential internal case title",
    }, reporter)[0]["id"]
    detail = f"{path}/{case}"
    notice = server.request(f"{detail}/actions", "POST", {
        "operation_id": str(uuid4()), "kind": "notice", "data": {
            "reference": "N-01", "agreement": "MECH-01", "body": "Internal notice draft.",
            "due_at": "2026-11-24T09:00:00+02:00",
        },
    }, reporter)[0]["id"]
    return detail, notice



def verify_source_fields(server, reporter, viewer, detail):
    def source(reference, extras):
        data = json.dumps({"reference": reference, "agreement": "MECH-01", "body": "Draft", **extras})
        return server.sql(
            "INSERT INTO ductdelta.case_event "
            "(organization_id, project_id, case_id, actor_id, operation_id, kind, reference, data) "
            f"SELECT organization_id, project_id, id, '{REPORTER}', gen_random_uuid(), 'notice', "
            f"$ref${reference}$ref$, $event${data}$event$::jsonb FROM ductdelta.change_case "
            f"WHERE id = '{detail.rsplit('/', 1)[-1]}' RETURNING id"
        )

    configured = source("N-CONFIGURED", {"notice_rule": {
        "recipient": "Mechanical Contract Administrator", "clause": "7.3",
        "issuer_name": "Named issuer", "issuer_actor_id": REPORTER, "service_method": "Project portal",
        "manual_instructions": "Internal rule notes",
    }})
    path = f"{detail}/notices/{configured}/copies"
    draft = {"operation_id": str(uuid4()), "recipient": "Incorrect recipient", "message": "Reviewed notice"}
    server.request(path, "POST", draft, reporter, expected=422)
    draft["recipient"] = "Mechanical Contract Administrator"
    copy = server.request(path, "POST", draft, reporter)[0]
    document = server.request(f"{path}/{copy['id']}/download", cookie=reporter)[0]
    for text in (b"Clause: 7.3", b"Issuer: Named issuer", b"Service method: Project portal"):
        assert text in document
    assert REPORTER.encode() not in document and b"Internal rule notes" not in document
    server.sql(
        f"UPDATE ductdelta.project_member SET permission = 'capture' "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'; "
        f"INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability) "
        f"SELECT organization_id, project_id, actor_id, 'direction' FROM ductdelta.project_member "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'"
    )
    revision = {**draft, "operation_id": str(uuid4()), "supersedes": copy["id"], "message": "Revised wording"}
    server.request(path, "POST", revision, viewer, expected=404)
    assert server.request(path, cookie=viewer)[0]["is_notice_issuer"] is False
    assert server.request(path, cookie=reporter)[0]["is_notice_issuer"] is True
    assert server.request(path, "POST", revision, reporter)[0]["version"] == 2
    share = {"operation_id": str(uuid4()), "token": token_hex(32)}
    link_path = f"{path}/{copy['id']}/links"
    link = server.request(link_path, "POST", share, reporter)[0]
    server.request(f"{link_path}/{link['id']}", "DELETE", cookie=viewer)
    server.request("/api/notice-copy", "POST", {"token": share["token"]}, expected=404)

    # Historical notice fields accepted literal line breaks before copy rendering existed.
    legacy = source("N-LEGACY\nRecipient: spoofed", {})
    path = f"{detail}/notices/{legacy}/copies"
    copy = server.request(path, "POST", draft, reporter)[0]
    document = server.request(f"{path}/{copy['id']}/download", cookie=reporter)[0]
    assert b'Reference: "N-LEGACY\\nRecipient: spoofed"\n' in document
    assert document.count(b"\nRecipient: ") == 1



def verify_closeout(server, reporter):
    detail, notice = seed_notice(server, reporter)
    path = f"{detail}/notices/{notice}/copies"
    draft = {"operation_id": str(uuid4()), "recipient": "Contract administrator", "message": "Recorded issue"}
    saved = server.request(path, "POST", draft, reporter)[0]
    for kind, data in (
        ("notice_dispatch", {
            "notice": notice, "reference": "Portal upload confirmation", "issued_copy": saved["id"],
            "recipient": saved["recipient"], "service_method": "Contract portal",
        }),
        ("close", {"reason": "No change required", "outcome": "no_change"}),
    ):
        server.request(f"{detail}/actions", "POST", {
            "operation_id": str(uuid4()), "kind": kind, "data": data,
        }, reporter)
    assert server.request(detail, cookie=reporter)[0]["closed"]
    assert server.request(path, "POST", draft, reporter)[0] == saved
    server.request(path, "POST", {
        **draft, "operation_id": str(uuid4()), "supersedes": saved["id"],
    }, reporter, expected=422)
    assert server.request(f"{path}/{saved['id']}/download", cookie=reporter)[0]


def verify(server, backup):
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    grant_demo_capabilities(server)
    detail, notice = seed_notice(server, reporter)
    copies = f"{detail}/notices/{notice}/copies"
    public = "/api/notice-copy"
    request = server.request

    def issue(recipient, message, supersedes=None):
        return {
            "operation_id": str(uuid4()), "recipient": recipient, "message": message, "supersedes": supersedes,
        }

    quote = {
        "operation_id": str(uuid4()), "kind": "quote", "data": {
            "reference": "CONFIDENTIAL-QUOTE", "lines": [{"description": "Private margin note", "amount": "329.50"}],
        },
    }
    request(f"{detail}/actions", "POST", quote, reporter)
    draft = issue("Alex at Mechanical Consultant", "A site change affects the duct route.\nPlease review Café A.")
    assert request(copies, cookie=reporter)[0] == {"copies": [], "is_notice_issuer": True}
    request(copies, "POST", draft, viewer, expected=404)
    request(copies, "POST", draft, outsider, expected=404)
    request(copies, "POST", draft, expected=401)
    wrong_project = copies.replace(PROJECT, OTHER_PROJECT)
    request(wrong_project, "POST", draft, reporter, expected=404)
    wrong_case = copies.replace(detail, f"/api/projects/{PROJECT}/cases/{uuid4()}")
    request(wrong_case, "POST", draft, reporter, expected=404)
    request(f"{detail}/notices/{uuid4()}/copies", cookie=reporter, expected=404)
    request(copies, "POST", {**draft, "recipient": "Alex\nDue: forged"}, reporter, expected=422)
    request(copies, "POST", {**draft, "message": "escape\x1b"}, reporter, expected=422)
    request(copies, "POST", {**draft, "message": " "}, reporter, expected=422)

    with ThreadPoolExecutor(max_workers=2) as executor:
        first, retry = executor.map(lambda _: request(copies, "POST", draft, reporter)[0], range(2))
    assert first == retry and first["version"] == 1 and first["supersedes"] is None
    request(copies, "POST", {**draft, "message": "Different"}, reporter, expected=409)
    request(copies, "POST", issue("Alex", "Stale first draft"), reporter, expected=409)
    copy_path = f"{copies}/{first['id']}"
    download = f"{copy_path}/download"
    original, headers = request(download, cookie=viewer)
    assert headers["Content-Disposition"] == 'attachment; filename="notice-version-1.txt"'
    assert headers["Content-Type"] == "text/plain; charset=utf-8" and headers["Cache-Control"] == "no-store"
    assert sha256(original).hexdigest() == first["sha256"]
    for field in (b"Version: 1", b"N-01", b"MECH-01", draft["recipient"].encode(), draft["message"].encode(),
                  b"2026-11-24T09:00:00+02:00"):
        assert field in original, field
    for field in (b"Confidential internal", b"Internal notice draft", b"Private margin note", b"329.50", REPORTER.encode()):
        assert field not in original
    request(download, expected=401)
    request(download, cookie=outsider, expected=404)

    def share(copy):
        grant = {"operation_id": str(uuid4()), "token": token_hex(32)}
        path = f"{copies}/{copy['id']}/links"
        link = request(path, "POST", grant, reporter)[0]
        assert request(path, "POST", grant, reporter)[0] == link
        assert "token" not in link and link["revoked_at"] is None
        request(path, "POST", {**grant, "token": token_hex(32)}, reporter, expected=409)
        request(path, "POST", {**grant, "operation_id": str(uuid4())}, viewer, expected=404)
        request(path, "POST", {"operation_id": str(uuid4()), "token": token_hex(32)}, reporter, expected=409)
        return grant, link

    first_grant, first_link = share(first)
    assert request(public, "POST", {"token": first_grant["token"]})[0] == original
    request(public, "POST", {"token": token_hex(32)}, expected=404)
    request(public, "POST", {"token": "invalid"}, expected=404)
    request(public, "POST", {"token": first_grant["token"]}, origin="https://invalid.example", expected=403)
    request(f"{detail}/files", expected=401)

    second = request(copies, "POST", issue("Alex", "Corrected route.", first["id"]), reporter)[0]
    assert second["version"] == 2 and second["supersedes"] == first["id"]
    records = request(copies, cookie=viewer)[0]["copies"]
    assert [copy["id"] for copy in records] == [second["id"], first["id"]]
    assert records[1]["sha256"] == first["sha256"]
    assert records[1]["link"]["id"] == first_link["id"]
    assert sha256(request(download, cookie=viewer)[0]).hexdigest() == first["sha256"]
    assert request(public, "POST", {"token": first_grant["token"]})[0] == original
    second_grant, _ = share(second)
    revised = request(public, "POST", {"token": second_grant["token"]})[0]
    assert revised != original and b"Corrected route." in revised
    assert sha256(revised).hexdigest() == second["sha256"]
    assert [event["kind"] for event in request(detail, cookie=reporter)[0]["events"]] == ["notice", "quote"]
    revoke = f"{copy_path}/links/{first_link['id']}"
    request(revoke, "DELETE", cookie=viewer, expected=404)
    revoked = request(revoke, "DELETE", cookie=reporter)[0]
    assert revoked["revoked_at"] and request(revoke, "DELETE", cookie=reporter)[0] == revoked
    request(public, "POST", {"token": first_grant["token"]}, expected=404)
    assert request(download, cookie=viewer)[0] == original
    expired_grant, expired_link = share(first)
    server.sql(
        "UPDATE ductdelta.issued_notice_link "
        "SET (created_at, expires_at) = (created_at - interval '8 days', expires_at - interval '8 days') "
        f"WHERE id = '{expired_link['id']}'"
    )
    request(public, "POST", {"token": expired_grant["token"]}, expected=404)
    replacement_grant, replacement_link = share(first)
    assert replacement_link["id"] != expired_link["id"]
    assert request(public, "POST", {"token": replacement_grant["token"]})[0] == original
    request(revoke, "DELETE", cookie=reporter)
    assert request(public, "POST", {"token": replacement_grant["token"]})[0] == original

    # Direct table access must fail for the actual web login.
    for query in (
        "SELECT bytes FROM ductdelta.issued_notice_copy",
        "SELECT token_digest FROM ductdelta.issued_notice_link",
        f"UPDATE ductdelta.issued_notice_copy SET recipient = 'Replaced' WHERE id = '{first['id']}'",
    ):
        try:
            server.sql(query, actor="dd_web")
        except subprocess.CalledProcessError as error:
            assert "permission denied" in error.stderr
        else:
            raise AssertionError("The web login bypassed the scoped functions")

    try:
        server.sql(f"UPDATE ductdelta.issued_notice_copy SET bytes = 'changed' WHERE id = '{first['id']}'")
    except subprocess.CalledProcessError as error:
        assert "immutable" in error.stderr
    else:
        raise AssertionError("An existing issued copy could be changed")

    verify_source_fields(server, reporter, viewer, detail)
    verify_closeout(server, reporter)
    subprocess.run([BIN / "pg_dump", "-Fc", "-f", backup, connection(server.database_socket, "dd_admin")],
                   check=True, env=server.environment, timeout=25)
    return viewer, download, original, first_grant, second_grant, revised


if __name__ == "__main__":
    with TemporaryDirectory() as directory:
        backup = Path(directory) / "notices.dump"
        trace_path = Path(directory) / "request.log"
        with trace_path.open("w") as trace:
            with workspace(service_env={"DUCTDELTA_TRACE_REQUESTS": "1"}, service_stderr=trace) as server:
                viewer, download, original, first_grant, second_grant, revised = verify(server, backup)
        log = trace_path.read_text()
        assert '"route":"/api/notice-copy"' in log
        assert first_grant["token"] not in log and second_grant["token"] not in log
        with workspace(backup=backup) as restored:
            assert restored.request(download, cookie=viewer)[0] == original
            assert restored.request("/api/notice-copy", "POST", {"token": second_grant["token"]})[0] == revised
            restored.request("/api/notice-copy", "POST", {"token": first_grant["token"]}, expected=404)
    print("PASS: exact bytes, SHA-256, authorization, idempotent issuance and links, supersession, expiry, revocation and restore")
