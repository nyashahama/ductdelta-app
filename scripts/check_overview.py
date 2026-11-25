#!/usr/bin/env python3
"""Check the scoped project overview and exact ledger totals through the running HTTP app."""

from datetime import date, datetime, time, timedelta, timezone
import json
from uuid import uuid4

from check_evidence_http import exchange
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


def verify_follow_ups(server):
    project = f"/api/projects/{PROJECT}"
    path = project + "/follow-ups"
    grant_demo_capabilities(server)
    reporter = server.sign_in(server.key(REPORTER, "Project lead"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))

    def post(url, **fields):
        return server.request(url, "POST", {"operation_id": str(uuid4()), **fields}, reporter)[0]["id"]

    def follow_ups(cookie=reporter, query=""):
        return server.request(path + query, cookie=cookie)[0]

    def tasks(case, cookie=reporter):
        entry = next(row for row in follow_ups(cookie)["cases"] if row["id"] == case)
        return {action["kind"]: action for action in entry["actions"]}, entry["evidence"]

    def attach(name, access):
        raw, _ = exchange(server, "POST", f"{project}/cases/{case}/files", reporter, 200, b"Original evidence", **{
            "Content-Type": "text/plain", "X-File-Name": name, "X-File-Access": access,
            "X-Operation-Id": str(uuid4()),
        })
        return json.loads(raw)["id"]

    server.request(path, expected=401)
    server.request(path, cookie=outsider, expected=404)
    for query in ("?page=0", "?page=-1", "?page=1.0", "?page=2147483648", "?page=1&page=2", "?days=7"):
        server.request(path + query, cookie=reporter, expected=422)
    assert follow_ups() == {"cases": [], "has_more": False}

    observation = post(project + "/observations", note="Duct reroute at a beam")
    case = post(project + "/cases", title="Duct reroute", observation_id=observation)
    actions_path = f"{project}/cases/{case}/actions"

    def action(kind, **fields):
        return post(actions_path, kind=kind, data=fields)

    original = attach("instruction.txt", "site")
    bank = attach("bank-proof.txt", "finance")
    instruction = action("instruction", reference="I-1", agreement="MECH-01", scope="Reroute the supply duct.")
    action("work", description="Reroute installed", completed=True, instruction=instruction)
    quote = action("quote", reference="Q-1", lines=[{"description": "Reroute", "amount": "25000.01"}])
    assert tasks(case)[0]["quote_decision"]["amount"] == "25000.01"
    action("decision", quote=quote, reason="Agreed", lines=[
        {"line": 1, "accepted": "25000.01", "disposition": "accepted"},
    ])
    assert tasks(case)[0]["uncertified"]["reference"] is None
    application = action("application", reference="PA-1", amount="25000.01")
    assert tasks(case)[0]["uncertified"]["amount"] == "25000.01"
    assert tasks(case)[0]["uncertified"]["reference"] == "PA-1"
    certificate = action("certificate", reference="PC-1", cumulative="20000.00", withheld="2000.00",
                         released="0", application=application)
    receipt = action("receipt", reference="BANK-1", amount="15000.00")
    assert tasks(case)[0]["unallocated"]["amount"] == "15000.00"
    action("allocate", reference="MATCH-1", receipt=receipt, certificate=certificate, amount="15000.00")
    actions, evidence = tasks(case)
    assert {kind: item["amount"] for kind, item in actions.items()} == {
        "uncertified": "5000.01", "collect": "3000.00", "retention": "2000.00",
    }
    assert evidence["observation_id"] == observation
    assert evidence["unpaid_certificates"] == ["PC-1"]
    assert {file["id"] for file in evidence["files"]} == {original, bank}
    assert evidence["file_count"] == 2
    actions, evidence = tasks(case, viewer)
    assert set(actions) == {"review"}
    assert evidence["references"] == [{"kind": "instruction", "reference": "I-1"}]
    assert evidence["unpaid_certificates"] == []
    assert [file["id"] for file in evidence["files"]] == [original] and evidence["file_count"] == 1
    server.sql(
        "INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability) "
        "SELECT organization_id, project_id, actor_id, 'commercial' FROM ductdelta.project_member "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{VIEWER}'"
    )
    actions, evidence = tasks(case, viewer)
    assert set(actions) == {"uncertified", "collect", "retention"}
    assert [file["id"] for file in evidence["files"]] == [original] and evidence["file_count"] == 1
    assert evidence["unpaid_certificates"] == ["PC-1"]
    assert "BANK-1" not in json.dumps(follow_ups(viewer))

    final_certificate = action("certificate", reference="PC-2", cumulative="25000.01", withheld="0",
                               released="0", predecessor=certificate)
    release = action("certificate", reference="PC-3", cumulative="25000.01", withheld="0",
                     released="2000.00", predecessor=final_certificate)
    final_cash = action("receipt", reference="BANK-2", amount="10000.01")
    for number, (certificate_id, amount) in enumerate((
        (certificate, "3000.00"), (final_certificate, "5000.01"), (release, "2000.00"),
    ), start=2):
        last_match = action("allocate", reference=f"MATCH-{number}", receipt=final_cash,
                            certificate=certificate_id, amount=amount)
    assert set(tasks(case)[0]) == {"review"}
    action("close", outcome="settled", reason="Completed, certified and paid")
    assert follow_ups()["cases"] == []
    action("reverse_allocation", allocation=last_match, reason="Corrected remittance")
    reopened, evidence = tasks(case)
    assert reopened["collect"]["amount"] == "2000.00" and evidence["unpaid_certificates"] == ["PC-3"]

    urgent = post(project + "/cases", title="Notice to send")
    due_at = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    pending = post(f"{project}/cases/{urgent}/actions", kind="notice", data={
        "reference": "N-1", "agreement": "MECH-01", "body": "Draft notice", "due_at": due_at,
    })
    assert follow_ups()["cases"][0]["id"] == urgent
    notice = tasks(urgent)[0]["notice"]
    assert notice["reference"] == "N-1" and datetime.fromisoformat(notice["due_at"]) == datetime.fromisoformat(due_at)
    notices_path = f"{project}/cases/{urgent}/notices/{pending}/copies"
    first_copy = post(notices_path, recipient="Contract administrator", message="Original notice", supersedes=None)
    assert tasks(urgent)[0]["notice"]["copy_id"] == first_copy
    dispatch = {"notice": pending, "recipient": "Contract administrator", "service_method": "Contract portal"}
    post(f"{project}/cases/{urgent}/actions", kind="notice_dispatch",
         data={**dispatch, "reference": "N-1 sent", "issued_copy": first_copy})
    assert set(tasks(urgent)[0]) == {"instruction"}
    updated_copy = post(notices_path, recipient="Contract administrator", message="Revised notice", supersedes=first_copy)
    revised = tasks(urgent)[0]["revised_notice"]
    assert revised["due_at"] is None and revised["copy_id"] == updated_copy and revised["version"] == 2
    post(f"{project}/cases/{urgent}/actions", kind="notice_dispatch",
         data={**dispatch, "reference": "N-1 revision sent", "issued_copy": updated_copy})
    assert set(tasks(urgent)[0]) == {"instruction"}

    closed = post(project + "/cases", title="Closed case")
    post(f"{project}/cases/{closed}/actions", kind="close", data={"outcome": "no_change", "reason": "No variation"})
    for number in range(8):
        post(project + "/cases", title=f"Open case {number}")
    first = follow_ups()
    second = follow_ups(query="?page=2")
    assert (len(first["cases"]), first["has_more"], len(second["cases"]), second["has_more"]) == (8, True, 2, False)
    first_ids = {row["id"] for row in first["cases"]}
    second_ids = {row["id"] for row in second["cases"]}
    assert not first_ids & second_ids and closed not in first_ids | second_ids
    print("PASS: prioritised follow-ups, exact certification and cash gaps, scoped evidence, and pagination")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
    with workspace() as server:
        verify_follow_ups(server)
