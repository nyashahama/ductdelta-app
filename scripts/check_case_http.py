#!/usr/bin/env python3
"""Replay a disputed change from field capture through financial closeout over HTTP."""

from uuid import uuid4

from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER, grant_demo_capabilities, workspace


def verify(server):
    project = f"/api/projects/{PROJECT}"
    cases = f"{project}/cases"
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    server.request(cases, cookie=outsider, expected=404)
    grant_demo_capabilities(server)
    observation = server.request(
        f"{project}/observations", "POST",
        {"operation_id": str(uuid4()), "note": "Installed equipment differs from tender."},
        reporter,
    )[0]
    draft = {
        "operation_id": str(uuid4()), "title": "Replace plantroom equipment",
        "observation_id": observation["id"],
    }
    server.request(cases, "POST", draft, viewer, expected=404)
    case = server.request(cases, "POST", draft, reporter)[0]
    assert server.request(cases, "POST", draft, reporter)[0] == case
    assert server.request(cases, cookie=viewer)[0] == {"next_before": None, "cases": [
        {"id": case["id"], "title": draft["title"], "closed": False},
    ]}
    detail = f"{cases}/{case['id']}"

    def read(cookie=reporter):
        return server.request(detail, cookie=cookie)[0]

    def record(kind, data, *, cookie=reporter, expected=200):
        return server.request(
            f"{detail}/actions", "POST",
            {"operation_id": str(uuid4()), "kind": kind, "data": data},
            cookie, expected=expected,
        )[0]

    assert read()["observation_id"] == observation["id"]
    assert read()["capabilities"] == ["commercial", "direction", "finance"]
    assert read(viewer)["capabilities"] == []
    record("notice", {"reference": "N-invalid", "agreement": "MECH-01",
                      "body": "Invalid date", "due_at": "2026-02-30T12:00:00Z"}, expected=422)
    notice = record("notice", {"reference": "N-01", "agreement": "MECH-01",
                               "body": "Changed plantroom equipment."})
    record("notice_dispatch", {"notice": notice["id"], "reference": "Portal #18"})
    record("notice_receipt", {"notice": notice["id"], "reference": "Portal #19"})
    instruction = record("instruction", {"reference": "I-01", "agreement": "MECH-01",
                                         "scope": "Replace plantroom equipment."})
    quote = record("quote", {"reference": "Q-01", "lines": [
        {"description": "Equipment", "amount": "80000"},
        {"description": "Handling", "amount": "10000"},
    ]})
    lines = [{"line": 1, "disposition": "accepted", "accepted": "80000"},
             {"line": 2, "disposition": "disputed", "accepted": "0"}]
    record("decision", {"quote": quote["id"], "lines": lines, "reason": "Handling disputed."})
    assert read()["financial"]["unresolved"] == "10000.00"
    assert read(viewer)["financial"] is None
    assert "quote" not in {event["kind"] for event in read(viewer)["events"]}
    record("work", {"description": "Equipment installed", "completed": True,
                    "instruction": instruction["id"]})
    application = record("application", {"reference": "A-01", "amount": "80000"})
    certificate = record("certificate", {"reference": "C-01", "cumulative": "80000",
                                         "withheld": "4000", "released": "0",
                                         "application": application["id"]})
    assert read()["financial"]["outstanding"] == "76000.00"
    settlement = {"reason": "Scope and cash reconciled", "outcome": "settled"}
    record("close", settlement, expected=422)
    lines[1] = {"line": 2, "disposition": "waived", "accepted": "0"}
    record("decision", {"quote": quote["id"], "lines": lines, "reason": "Claim withdrawn."})
    release = record("certificate", {"reference": "REL-01", "cumulative": "80000",
                                     "withheld": "0", "released": "4000",
                                     "predecessor": certificate["id"]})
    receipt = record("receipt", {"reference": "R-01", "amount": "80000"})
    record("allocate", {"receipt": receipt["id"], "certificate": certificate["id"],
                        "amount": "76000", "reference": "R-01/C-01"})
    allocation = record("allocate", {"receipt": receipt["id"], "certificate": release["id"],
                                     "amount": "4000", "reference": "R-01/REL-01"})
    assert read()["financial"]["matched"] == "80000.00"
    record("close", settlement)
    assert read()["closed"] is True
    record("reverse_allocation", {"allocation": allocation["id"], "reason": "Correction"})
    reopened = read()
    assert reopened["closed"] is False
    assert reopened["financial"]["outstanding"] == "4000.00"
    assert reopened["events"][-2]["kind"] == "close"
    print("PASS: disputed change, restricted finance, retention, split allocation, closeout and reopening over HTTP")

    server.sql(
        "INSERT INTO ductdelta.change_case "
        "(organization_id, project_id, actor_id, operation_id, title, recorded_at) "
        "SELECT item.organization_id, item.project_id, item.actor_id, gen_random_uuid(), "
        "'Pagination ' || index, item.recorded_at + interval '1 second' "
        "FROM ductdelta.change_case AS item CROSS JOIN generate_series(1, 101) AS index "
        f"WHERE item.id = '{case['id']}'"
    )
    first = server.request(cases, cookie=viewer)[0]
    assert len(first["cases"]) == 100 and first["next_before"] == first["cases"][-1]["id"]
    rest = server.request(f"{cases}?before={first['next_before']}", cookie=viewer)[0]
    assert len(rest["cases"]) == 2 and rest["next_before"] is None
    assert rest["cases"][-1]["id"] == case["id"]
    assert len({item["id"] for item in first["cases"] + rest["cases"]}) == 102
    server.request(f"{cases}?before={uuid4()}", cookie=viewer, expected=404)
    print("PASS: case register remains traversable through pages and exact time ties")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
