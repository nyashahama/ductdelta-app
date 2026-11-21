#!/usr/bin/env python3
"""Exercise dispute closeout, audit history, and visibility over the workspace API."""

from uuid import uuid4

from check_workspace import PROJECT, REPORTER, VIEWER, grant_demo_capabilities, workspace


def verify(server):
    grant_demo_capabilities(server)
    manager = server.sign_in(server.key(REPORTER, "Commercial lead"))
    viewer = server.sign_in(server.key(VIEWER, "Site viewer"))
    cases = f"/api/projects/{PROJECT}/cases"
    case = server.request(cases, "POST", {"operation_id": str(uuid4()), "title": "Disputed fabrication"}, manager)[0]
    path = f"{cases}/{case['id']}"

    def action(kind, data, expected=200, cookie=manager, operation=None):
        return server.request(
            path + "/actions", "POST",
            {"kind": kind, "data": data, "operation_id": operation or str(uuid4())},
            cookie, expected=expected,
        )[0]

    def detail(cookie=manager):
        return server.request(path, cookie=cookie)[0]

    notice = action("notice", {"reference": "N-1", "agreement": "MECH-1", "body": "Unconfirmed workshop charge."})
    action("notice_dispatch", {"notice": notice["id"], "reference": "Dispatch 1"})
    quote = action("quote", {"reference": "Q-1", "lines": [
        {"description": "Fabrication charge", "amount": "100"},
        {"description": "Disputed return credit", "amount": "-100"},
    ]})
    close = {"outcome": "no_change", "reason": "No change to the award."}
    action("close", close, expected=422)
    decision = {"quote": quote["id"], "reason": "Both lines remain contested.", "lines": [
        {"line": 1, "accepted": "0", "disposition": "disputed"},
        {"line": 2, "accepted": "0", "disposition": "disputed"},
    ]}
    action("decision", decision)
    totals = detail()["financial"]
    assert totals["unresolved"] == "0.00" and totals["unresolved_lines"] == 2
    assert detail(viewer)["financial"] is None
    for outcome in ("no_change", "rejected", "withdrawn", "settled"):
        result = action("close", {**close, "outcome": outcome}, expected=422)
        assert result["message"] == "Resolve every open or disputed quote line before closing the case."
    assert not detail()["closed"]

    waived = [{**line, "disposition": "waived"} for line in decision["lines"]]
    action("decision", {**decision, "lines": waived, "reason": "Both parties withdrew their claims."})
    closed = action("close", close)
    assert detail()["closed"]
    action("reopen", {"reason": "The original transmittal was recovered."}, expected=404, cookie=viewer)
    reopen = {"reason": "The original transmittal was recovered."}
    operation = str(uuid4())
    opened = action("reopen", reopen, operation=operation)
    assert action("reopen", reopen, operation=operation) == opened
    action("reopen", {**reopen, "reason": "A different reason"}, operation=operation, expected=409)
    action("reopen", reopen, expected=422)
    result = detail()
    assert result["closed"] is False
    assert [event["id"] for event in result["events"][-2:]] == [closed["id"], opened["id"]]
    assert result["events"][-1]["data"]["reason"] == reopen["reason"]
    action("decision", decision)
    assert detail()["financial"]["unresolved_lines"] == 2
    print("PASS: unresolved-line count, every close outcome, scoped reopen, replay and preserved closeout history")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
