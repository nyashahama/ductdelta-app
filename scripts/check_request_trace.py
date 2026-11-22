#!/usr/bin/env python3
"""Verify request IDs and production-safe route logs."""

import json
import secrets
from tempfile import TemporaryFile
from uuid import UUID, uuid4

from check_company_team import company
from check_workspace import workspace


with TemporaryFile(mode="w+b") as output:
    with workspace(
        seed=False, service_env={"DUCTDELTA_TRACE_REQUESTS": "1"}, service_stderr=output,
    ) as server:
        path, admin = company(server, "Synthetic Company")
        project = server.request(f"{path}/projects", "POST", {
            "name": "Synthetic project", "operation_id": str(uuid4()),
        }, admin, expected=201)[0]["id"]
        private = secrets.token_hex(32)
        _, overview = server.request(f"/api/projects/{project}/overview?test={private}", cookie=admin, expected=422)
        _, rejected = server.request("/api/session", "POST", {"key": private}, expected=401)
        assert overview["X-Request-Id"] and rejected["X-Request-Id"], "HTTP response has no request ID"
        assert UUID(overview["X-Request-Id"]) != UUID(rejected["X-Request-Id"])
    output.seek(0)
    stream = output.read().decode()
    assert private not in stream and admin not in stream and project not in stream
    logs = {event["request_id"]: event for event in map(json.loads, stream.splitlines()) if event["event"] == "http_request"}
    safe = logs[overview["X-Request-Id"]]
    assert safe["route"] == "/api/projects/{project}/overview" and safe["method"] == "GET" and safe["status"] == 422
    assert safe["elapsed_ms"] >= 0
    denied = logs[rejected["X-Request-Id"]]
    assert denied["route"] == "/api/session" and denied["method"] == "POST" and denied["status"] == 401
    print("PASS: request IDs correlate safe route logs without project identifiers, query secrets, cookies or keys")
