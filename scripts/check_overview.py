#!/usr/bin/env python3
"""Check the scoped project overview and exact ledger totals through the running HTTP app."""

from datetime import date, datetime, time, timedelta, timezone
from uuid import uuid4

from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER
from check_workspace import grant_demo_capabilities, workspace
from check_postgres import SECOND_ORGANIZATION_PROJECT


def verify(server):
    project = f"/api/projects/{PROJECT}"
    path = f"{project}/overview"
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    today = date.fromisoformat(server.sql("SELECT (statement_timestamp() AT TIME ZONE 'UTC')::date"))
    server.sql("ALTER ROLE dd_web SET timezone = 'Pacific/Auckland'")

    def overview(cookie=reporter, query=""):
        return server.request(f"{path}{query}", cookie=cookie)[0]

    def instant(offset, local_clock=time()):
        return datetime.combine(today + timedelta(days=offset), local_clock, timezone.utc).isoformat()

    server.request(path, expected=401)
    server.request(path, cookie=outsider, expected=404)
    for value in ("0", "15", "-7", "30.0", "bad", "", "7&days=30"):
        server.request(f"{path}?days={value}", cookie=viewer, expected=422)

    empty, headers = server.request(path, cookie=viewer)
    assert headers["Cache-Control"] == "no-store"
    assert {key: empty[key] for key in ("open_cases", "without_instruction", "notices_due",
                                       "observations", "financial", "cases", "notices")} == {
        "open_cases": 0, "without_instruction": 0, "notices_due": 0, "observations": 0,
        "financial": None, "cases": [], "notices": [],
    }
    expected_dates = [(today + timedelta(days=offset)).isoformat() for offset in range(-13, 1)]
    assert [row["day"] for row in empty["activity"]] == expected_dates
    assert all(not row["observations"] and not row["cases"] for row in empty["activity"])
    assert overview(viewer, "?days=14") == empty

    grant_demo_capabilities(server)
    assert overview()["financial"] == {
        "certified": "0.00", "retained": "0.00", "matched": "0.00", "outstanding": "0.00",
        "currency": "ZAR", "basis": "excl_vat",
    }

    def case(title, project_path=project, cookie=reporter):
        return server.request(f"{project_path}/cases", "POST",
                              {"operation_id": str(uuid4()), "title": title}, cookie)[0]["id"]

    def action(case_id, kind, data):
        return server.request(
            f"{project}/cases/{case_id}/actions", "POST",
            {"operation_id": str(uuid4()), "kind": kind, "data": data}, reporter,
        )[0]["id"]

    def notice(case_id, reference, deadline=None):
        data = {"reference": reference, "agreement": "MECH-01", "body": "Synthetic written notice"}
        if deadline is not None:
            data["due_at"] = deadline
        return action(case_id, "notice", data)

    def observation(recorded_at):
        created = server.request(f"{project}/observations", "POST",
                                 {"operation_id": str(uuid4()), "note": "Recorded observation"},
                                 reporter)[0]["id"]
        server.sql(f"UPDATE ductdelta.observation SET recorded_at = '{recorded_at}' WHERE id = '{created}'")

    open_case = case("Pending scope", project)
    certified_case = case("Certified scope", project)
    credit_case = case("Credit scope", project)
    closed_case = case("Closed scope", project)
    other_project = f"/api/projects/{SECOND_ORGANIZATION_PROJECT}"
    case("Other company title", other_project, outsider)
    action(closed_case, "close", {"reason": "No change", "outcome": "no_change"})
    server.sql(f"UPDATE ductdelta.change_case SET recorded_at = '{instant(-6)}' WHERE id = '{open_case}'")
    server.sql(f"UPDATE ductdelta.change_case SET recorded_at = '{instant(0)}' WHERE id = '{certified_case}'")

    observation(instant(-7, time(23, 59, 59)))
    observation(instant(-6))
    observation(instant(0))
    observation(instant(1))
    notice(open_case, "OVERDUE", instant(-1))
    notice(open_case, "DUE-NEXT-WEEK", instant(7, time(23, 59, 59)))
    notice(open_case, "NO-DEADLINE")
    dispatched = notice(open_case, "ALREADY-DISPATCHED", instant(0))
    action(open_case, "notice_dispatch", {"notice": dispatched, "reference": "PORTAL-01"})
    notice(certified_case, "OUTSIDE-HORIZON", instant(8))
    action(certified_case, "instruction", {"reference": "I-01", "agreement": "MECH-01", "scope": "Site work"})
    certificate = action(certified_case, "certificate", {
        "reference": "C-01", "cumulative": "100.00", "withheld": "10.00", "released": "0",
    })
    receipt = action(certified_case, "receipt", {"reference": "R-01", "amount": "25.00"})
    action(certified_case, "allocate", {
        "receipt": receipt, "certificate": certificate, "reference": "R-01/C-01", "amount": "25.00",
    })
    action(credit_case, "instruction", {"reference": "I-01", "agreement": "MECH-02", "scope": "Omission"})
    action(credit_case, "certificate", {
        "reference": "C-credit", "cumulative": "-10.00", "withheld": "0", "released": "0",
    })

    seven = overview(viewer, "?days=7")
    assert len(seven["activity"]) == 7 and seven["activity"][0] == {
        "day": (today - timedelta(days=6)).isoformat(), "observations": 1, "cases": 1,
    }
    assert seven["activity"][-1]["day"] == today.isoformat()
    assert seven["activity"][-1]["observations"] == 1
    assert seven["activity"][-1]["cases"] == 3
    assert len(overview(viewer, "?days=30")["activity"]) == 30
    assert seven["observations"] == 4 and seven["open_cases"] == 3
    assert seven["without_instruction"] == 1 and seven["notices_due"] == 2
    assert [item["reference"] for item in seven["notices"]] == ["OVERDUE", "DUE-NEXT-WEEK"]
    assert {item["id"] for item in seven["cases"]} == {open_case, certified_case, credit_case}
    rows = {item["id"]: item for item in seven["cases"]}
    assert rows[open_case]["has_instruction"] is False and rows[certified_case]["has_instruction"] is True
    assert datetime.fromisoformat(rows[open_case]["notice_due_at"]) == datetime.fromisoformat(instant(-1))
    assert datetime.fromisoformat(rows[certified_case]["notice_due_at"]) == datetime.fromisoformat(instant(8))
    assert rows[credit_case]["notice_due_at"] is None
    assert seven["financial"] is None
    financial = overview()["financial"]
    assert financial == {
        "certified": "90.00", "retained": "10.00", "matched": "25.00", "outstanding": "55.00",
        "currency": "ZAR", "basis": "excl_vat",
    }

    server.sql(
        "INSERT INTO ductdelta.project_workflow_grant "
        "(organization_id, project_id, actor_id, capability) "
        "SELECT organization_id, project_id, actor_id, 'commercial' FROM ductdelta.project_member "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'"
    )
    assert overview(viewer)["financial"] == financial
    server.sql(f"DELETE FROM ductdelta.project_workflow_grant WHERE project_id = '{PROJECT}' "
               f"AND actor_id = '{REPORTER}' AND capability = 'commercial'")
    assert overview()["financial"] == financial
    server.sql(f"DELETE FROM ductdelta.project_workflow_grant WHERE project_id = '{PROJECT}' "
               f"AND actor_id = '{REPORTER}' AND capability = 'finance'")
    assert overview()["financial"] is None
    recent = [case(f"New project case {number}") for number in range(9)]
    for number in range(6):
        notice(open_case, f"NEAR-{number}", instant(number))
    limited = overview(viewer)
    assert [item["id"] for item in limited["cases"]] == list(reversed(recent[1:]))
    assert limited["open_cases"] == 12 and limited["notices_due"] == 8
    assert [item["reference"] for item in limited["notices"]] == [
        "OVERDUE", "NEAR-0", "NEAR-1", "NEAR-2", "NEAR-3",
    ]
    server.sql(f"DELETE FROM ductdelta.project_member WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'")
    server.request(path, cookie=viewer, expected=404)
    assert server.request(f"{other_project}/overview", cookie=outsider)[0]["open_cases"] == 1
    print("PASS: overview UTC windows, deadline and case summaries, isolated access, exact signed totals and revocation")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
