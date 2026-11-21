#!/usr/bin/env python3
"""Verify that original evidence bytes and their authorization survive the HTTP boundary."""

import hashlib
from http.client import HTTPConnection
import json
import subprocess
from urllib.parse import quote
from uuid import uuid4

from check_postgres import BIN, connection
from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER
from check_workspace import grant_demo_capabilities, workspace


def exchange(server, method, path, cookie, expected, body=None, **headers):
    connection = HTTPConnection("127.0.0.1", server.port, timeout=15)
    try:
        connection.request(method, path, body=body, headers={
            "Origin": server.origin, "Cookie": cookie, **headers,
        })
        response = connection.getresponse()
        payload = response.read()
        assert response.status == expected, (response.status, expected, payload[:300])
        return payload, response.headers
    finally:
        connection.close()


def verify(server):
    grant_demo_capabilities(server)
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    case = server.request(
        f"/api/projects/{PROJECT}/cases", "POST",
        {"operation_id": str(uuid4()), "title": "Evidence retention"}, reporter,
    )[0]
    files = f"/api/projects/{PROJECT}/cases/{case['id']}/files"
    name = "First quotation à.txt"
    original = ("Observation and original measurement.\n" * 4000).encode()
    headers = {
        "Content-Type": "text/plain",
        "X-File-Name": quote(name),
        "X-File-Caption": quote("Original contractor's description"),
        "X-File-Access": "site",
        "X-Operation-Id": str(uuid4()),
    }
    raw, _ = exchange(server, "POST", files, reporter, 200, original, **headers)
    saved = json.loads(raw)
    assert saved["sha256"] == hashlib.sha256(original).hexdigest() and saved["filename"] == name
    assert saved["caption"] == "Original contractor's description"
    assert json.loads(exchange(server, "POST", files, reporter, 200, original, **headers)[0]) == saved
    exchange(server, "POST", files, reporter, 409, original + b"x", **headers)
    exchange(server, "POST", files, viewer, 404, original, **headers)
    exchange(server, "POST", files, reporter, 413, bytes(5 * 1024 * 1024 + 1), **headers)
    source = f"{files}/{saved['id']}"
    downloaded, response_headers = exchange(server, "GET", source, viewer, 200)
    assert downloaded == original
    assert response_headers["Content-Disposition"] == (
        f"attachment; filename=\"original.txt\"; filename*=UTF-8''{quote(name)}"
    )
    assert response_headers["X-Content-Type-Options"] == "nosniff"
    assert response_headers["Cache-Control"] == "no-store"
    exchange(server, "GET", source, outsider, 404)
    malformed = headers | {"X-File-Name": "%00"}
    exchange(server, "POST", files, reporter, 422, b"invalid metadata", **malformed)

    restricted = headers | {"X-File-Access": "finance", "X-Operation-Id": str(uuid4())}
    bank, _ = exchange(server, "POST", files, reporter, 200, b"Private proof.", **restricted)
    bank_source = f"{files}/{json.loads(bank)['id']}"
    exchange(server, "GET", bank_source, viewer, 404)
    assert server.request(files, cookie=viewer)[0] == [saved]
    assert len(server.request(files, cookie=reporter)[0]) == 2
    print("PASS: exact evidence bytes, explicit attachment headers, bounded uploads, retries and read restrictions")


    detail = f"/api/projects/{PROJECT}/cases/{case['id']}"

    def action(kind, **data):
        return server.request(
            f"{detail}/actions", "POST",
            {"operation_id": str(uuid4()), "kind": kind, "data": data}, reporter,
        )[0]["id"]

    action("instruction", reference="I-01", agreement="MECH-01", scope="Document the change")
    certificate = action("certificate", reference="C-01", cumulative="20.05", withheld="0",
                         released="0", reason="Original certificate checked")
    receipt = action("receipt", reference="R-01", amount="20.05")
    action("allocate", receipt=receipt, certificate=certificate, amount="10.25", reference="Allocation 1")
    expected = server.request(detail, cookie=reporter)[0]
    assert expected["financial"]["outstanding"] == "9.80"

    dump = server.database_socket.parent / "workspace.dump"
    subprocess.run(
        [BIN / "pg_dump", "--format=custom", f"--file={dump}",
         connection(server.database_socket, "dd_admin")],
        env=server.environment, check=True, timeout=25,
    )
    with workspace(backup=dump) as restored:
        assert restored.request(detail, cookie=reporter)[0] == expected
        assert restored.request(files, cookie=viewer)[0] == [saved]
        assert exchange(restored, "GET", source, viewer, 200)[0] == original
        exchange(restored, "GET", bank_source, viewer, 404)
        exchange(restored, "GET", source, outsider, 404)
    print("PASS: fresh PostgreSQL restore preserves the ledger, exact files and authorized access")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
