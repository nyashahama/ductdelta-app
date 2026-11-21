#!/usr/bin/env python3
"""Check the manual case and financial workflow on a disposable PostgreSQL cluster."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import uuid

from check_postgres import BIN, PROJECT, ROOT, SECOND_ORGANIZATION_PROJECT, connection, disposable_cluster


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def run(socket, auth_migration):
    def sql(statement, *, login="dd_web_test", error=None):
        result = subprocess.run(
            [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose",
             connection(socket, login)],
            input=statement, capture_output=True, text=True, timeout=15, check=False,
            env={key: value for key, value in os.environ.items() if not key.startswith("PG")},
        )
        if error:
            assert result.returncode == 3 and error in result.stderr, result.stderr
            return None
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def admin(statement):
        return sql(statement, login="dd_admin")

    for name in ("0001_capture.sql", "0002_list_observations.sql"):
        admin((ROOT / "migrations" / name).read_text())
    admin((ROOT / "tests" / "roles.sql").read_text())
    admin((ROOT / "tests" / "fixture.sql").read_text())
    admin(auth_migration.read_text())
    admin("CREATE ROLE dd_web_test LOGIN IN ROLE ductdelta_web_runtime")
    for path in sorted((ROOT / "migrations").glob("000[45]_*.sql")):
        admin(path.read_text())

    reporter = "decode(repeat('a1', 32), 'hex')"
    viewer = "decode(repeat('a2', 32), 'hex')"
    other = "decode(repeat('a4', 32), 'hex')"
    invalid = "decode(repeat('a5', 32), 'hex')"
    for actor_suffix, name, session in (("1", "reporter", reporter), ("2", "viewer", viewer),
                                        ("4", "other", other)):
        key = f"sha256(convert_to('synthetic workflow {name}', 'UTF8'))"
        admin(
            "INSERT INTO ductdelta.web_access_key (actor_id, display_name, key_digest, expires_at) "
            f"VALUES ('20000000-0000-0000-0000-00000000000{actor_suffix}',"
            f"'{name}', {key}, statement_timestamp() + interval '1 day')"
        )
        assert sql(f"SELECT ductdelta.web_login({key}, {session})") == "t"
    operation = str(uuid.uuid4())

    def create(title, *, op=operation, session=reporter, project=PROJECT, observation=None, error=None):
        source = "NULL" if observation is None else quote(observation)
        row = sql(
            f"SELECT ductdelta.web_create_case({session}, '{project}', '{op}', {quote(title)}, {source})",
            error=error,
        )
        return json.loads(row)["id"] if row is not None else None

    def detail(*, session=reporter, project=PROJECT, case=None, error=None):
        row = sql(f"SELECT ductdelta.web_case({session}, '{project}', '{case or case_id}')",
                  error=error)
        return json.loads(row) if row is not None else None

    def action(kind, payload, *, op=None, session=reporter, case=None, error=None):
        row = sql(
            f"SELECT ductdelta.web_case_action({session}, '{PROJECT}', '{case or case_id}', "
            f"'{op or uuid.uuid4()}', {quote(kind)}, {quote(json.dumps(payload))}::jsonb)",
            error=error,
        )
        return json.loads(row)["id"] if row is not None else None

    case_id = create("Replace chillers")
    assert create("Replace chillers") == case_id
    create("Changed title", error="DD001")
    create("Viewer cannot create", session=viewer, error="42501")
    create("Expired session", session=invalid, error="28000")
    create("Wrong organization", session=other, error="42501")
    other_case = create("Other company", op=str(uuid.uuid4()), session=other,
                        project=SECOND_ORGANIZATION_PROJECT)
    detail(case=other_case, error="42501")
    detail(session=other, error="42501")
    listed = json.loads(sql(f"SELECT ductdelta.web_cases({viewer}, '{PROJECT}')"))
    assert listed == {"cases": [{"id": case_id, "title": "Replace chillers", "closed": False}],
                      "next_before": None}
    sql("SELECT * FROM ductdelta.change_case", error="42501")
    sql("SELECT ductdelta.case_totals(NULL)", error="42501")
    source = sql(f"SELECT ductdelta.capture_observation('{PROJECT}', '{uuid.uuid4()}', "
                 "NULL, NULL, 'Observed older equipment')", login="dd_reporter")
    linked = create("Linked evidence", op=str(uuid.uuid4()), observation=source)
    assert detail(case=linked)["observation_id"] == source
    create("Foreign observation", op=str(uuid.uuid4()), observation=source, session=other,
           project=SECOND_ORGANIZATION_PROJECT, error="42501")
    assert detail()["events"] == []
    assert detail(session=viewer)["financial"] is None

    notice_payload = {"reference": "N-01", "agreement": "A-01", "body": "Notice of change"}
    action("notice", notice_payload, error="42501")
    for capability in ("direction", "commercial", "finance"):
        admin(
            "INSERT INTO ductdelta.project_workflow_grant "
            "(organization_id, project_id, actor_id, capability) SELECT organization_id, "
            f"project_id, actor_id, '{capability}' FROM ductdelta.project_member "
            f"WHERE project_id = '{PROJECT}' AND permission = 'capture'"
        )
    notice = action("notice", notice_payload)
    action("notice_receipt", {"notice": notice, "reference": "Receipt-01"}, error="23514")
    action("notice_dispatch", {"notice": notice, "reference": "Portal-01"})
    action("notice_receipt", {"notice": notice, "reference": "Receipt-01"})
    action("work", {"description": "Survey visit", "completed": False})
    act_operation = str(uuid.uuid4())
    instruction_payload = {"reference": "I-01", "agreement": "A-01", "scope": "Chiller replacement"}
    instruction = action("instruction", instruction_payload, op=act_operation)
    assert action("instruction", instruction_payload, op=act_operation) == instruction
    action("instruction", {**instruction_payload, "scope": "Other scope"},
           op=act_operation, error="DD001")
    action("instruction", {**instruction_payload, "agreement": "A-02"}, error="23514")
    action("work", {"description": "Chillers replaced", "completed": True, "instruction": instruction})
    assert [event["kind"] for event in detail()["events"]] == [
        "notice", "notice_dispatch", "notice_receipt", "work", "instruction", "work",
    ]
    print("PASS: case isolation, distinct notice history, factual work and authorized instruction")
    quote_id = action("quote", {"reference": "Q-01", "lines": [
        {"description": "Replacement chillers", "amount": "440000.00"},
        {"description": "Omitted equipment", "amount": "-390000"},
        {"description": "Pipework and controls", "amount": "80000"},
        {"description": "Disputed handling", "amount": "10000"},
    ]})
    assert detail()["financial"]["proposed"] == "140000.00"
    assert detail()["financial"]["agreed"] is None
    decision_lines = [
        {"line": 1, "accepted": "440000", "disposition": "accepted"},
        {"line": 2, "accepted": "-390000", "disposition": "accepted"},
        {"line": 3, "accepted": "80000", "disposition": "accepted"},
        {"line": 4, "accepted": "0", "disposition": "disputed"},
    ]
    action("decision", {"quote": quote_id, "reason": "Partial", "lines": decision_lines})
    assert detail()["financial"]["agreed"] == "130000.00"
    assert detail()["financial"]["unresolved"] == "10000.00"
    assert detail(session=viewer)["financial"] is None
    assert "quote" not in {event["kind"] for event in detail(session=viewer)["events"]}
    action("certificate", {"reference": "invalid", "cumulative": "80000.001",
                           "withheld": "4000", "released": "0"}, error="22023")

    def expect_money(**expected):
        financial = detail()["financial"]
        assert all(financial[key] == value for key, value in expected.items()), financial

    def certificate(reference, cumulative, withheld="0", released="0", predecessor=None):
        payload = {"reference": reference, "cumulative": cumulative,
                   "withheld": withheld, "released": released}
        if predecessor:
            payload["predecessor"] = predecessor
        return action("certificate", payload)

    def receipt(reference, amount):
        return action("receipt", {"reference": reference, "amount": amount})

    def allocate(source, target, amount, reference, *, error=None):
        return action("allocate", {"receipt": source, "certificate": target,
                                   "amount": amount, "reference": reference}, error=error)

    a1 = action("application", {"reference": "A-01", "amount": "90000"})
    c1 = action("certificate", {"reference": "C1", "cumulative": "80000", "withheld": "4000",
                                "released": "0", "application": a1})
    expect_money(certified="80000.00", retained="4000.00", payable="76000.00")
    r1 = receipt("R1", "70000")
    allocate(r1, c1, "60000", "R1-C1")
    expect_money(outstanding="16000.00", unallocated="10000.00")
    action("close", {"reason": "Premature", "outcome": "settled"}, error="23514")
    action("certificate", {"reference": "C-missing", "cumulative": "130000",
                           "withheld": "2500", "released": "0"}, error="23514")
    c2 = certificate("C2", "130000", "2500", predecessor=c1)
    certificate_event = next(event for event in detail()["events"] if event["id"] == c2)
    assert certificate_event["data"]["financial_snapshot"] == {
        "work_delta": "50000.00", "payable": "47500.00",
    }
    expect_money(certified="130000.00", payable="123500.00", retained="6500.00")
    r2 = receipt("R2", "54000")
    allocate(r2, c1, "16000", "R2-C1")
    allocate(r2, c2, "38001", "R2-too-much", error="23514")
    allocate(r2, c2, "38000", "R2-C2")
    allocate(r1, c2, "9500", "R1-C2")
    expect_money(outstanding="0.00", unallocated="500.00")
    decision_lines[-1] = {"line": 4, "accepted": "6000", "disposition": "waived"}
    action("decision", {"quote": quote_id, "reason": "Settled", "lines": decision_lines})
    c3 = certificate("C3", "136000", "300", predecessor=c2)
    allocate(r1, c3, "500", "R1-C3")
    expect_money(agreed="136000.00", retained="6800.00", outstanding="5200.00",
                 unallocated="0.00")
    action("certificate", {"reference": "Over-release", "cumulative": "136000", "withheld": "0",
                           "released": "6801", "predecessor": c3}, error="23514")
    release = certificate("REL-01", "136000", released="6800", predecessor=c3)
    expect_money(certified="136000.00", retained="0.00", outstanding="12000.00")
    r3 = receipt("R3", "12000")
    allocate(r3, c3, "5200", "R3-C3")
    last_allocation = allocate(r3, release, "6800", "R3-REL")
    expect_money(payable="136000.00", matched="136000.00", outstanding="0.00",
                 unallocated="0.00", unresolved="0.00")

    close_payload = {"reason": "Handover and matching confirmed", "outcome": "settled"}
    close_operation = str(uuid.uuid4())
    close_id = action("close", close_payload, op=close_operation)
    assert detail()["closed"]
    assert action("close", close_payload, op=close_operation) == close_id
    reverse_payload = {"allocation": last_allocation, "reason": "Remittance correction"}
    reverse_operation = str(uuid.uuid4())
    reverse_id = action("reverse_allocation", reverse_payload, op=reverse_operation)
    assert action("reverse_allocation", reverse_payload, op=reverse_operation) == reverse_id
    action("reverse_allocation", reverse_payload, error="23514")
    changed = detail()
    assert not changed["closed"]
    assert changed["events"][-2]["id"] == close_id
    expect_money(outstanding="6800.00", unallocated="6800.00")
    assert changed["events"][-2]["data"]["financial_snapshot"]["outstanding"] == "0.00"
    assert "financial_snapshot" not in detail(session=viewer)["events"][-1]["data"]

    def allocate_reopened(index):
        return allocate(r3, release, "6800", f"Race-{index}")

    with ThreadPoolExecutor(max_workers=2) as executor:
        competing = [executor.submit(allocate_reopened, index) for index in range(2)]
    assert sum(result.exception() is None for result in competing) == 1
    assert any("23514: Allocation exceeds" in str(result.exception()) for result in competing)
    expect_money(outstanding="0.00", unallocated="0.00")

    viewer_id = "20000000-0000-0000-0000-000000000002"
    admin(
        "INSERT INTO ductdelta.project_workflow_grant "
        "(organization_id, project_id, actor_id, capability) SELECT organization_id, "
        f"project_id, actor_id, 'commercial' FROM ductdelta.project_member "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{viewer_id}'"
    )
    commercial = detail(session=viewer)
    assert commercial["financial"]["matched"] == "136000.00"
    assert commercial["financial"]["unallocated"] is None
    assert not ({"receipt", "allocate", "reverse_allocation"} & {e["kind"] for e in commercial["events"]})
    action("receipt", {"reference": "R4", "amount": "1"}, session=viewer, error="42501")
    admin(f"DELETE FROM ductdelta.project_workflow_grant WHERE project_id = '{PROJECT}' "
          "AND actor_id = '20000000-0000-0000-0000-000000000001' AND capability = 'direction'")
    action("instruction", instruction_payload, op=act_operation, error="42501")
    sql(f"SELECT ductdelta.web_logout({viewer})")
    detail(session=viewer, error="28000")
    no_change_case = create("No change on inspection", op=str(uuid.uuid4()))
    action("work", {"description": "Inspected and found no change", "completed": True},
           case=no_change_case)
    action("close", {"reason": "No scope or financial impact", "outcome": "no_change"},
           case=no_change_case)
    assert detail(case=no_change_case)["closed"]
    print("PASS: quote decisions, cumulative certificates, retention, split cash, closeout and reversal")

    # A new proposal does not erase the current agreement or settle the new proposal.
    grant = ("INSERT INTO ductdelta.project_workflow_grant "
             "(organization_id, project_id, actor_id, capability) SELECT organization_id, "
             "project_id, actor_id, 'direction' FROM ductdelta.project_member "
             f"WHERE project_id = '{PROJECT}' AND permission = 'capture'")
    admin(grant)
    revised_case = create("One case with revised pricing and separate scope", op=str(uuid.uuid4()))
    instruction_payload = {"reference": "I-01", "agreement": "A-01", "scope": "First scope"}
    first_instruction = action("instruction", instruction_payload, case=revised_case)
    second_instruction = action(
        "instruction", {**instruction_payload, "reference": "I-02", "scope": "Second scope"},
        case=revised_case,
    )
    action("work", {"description": "First scope complete", "completed": True,
                    "instruction": first_instruction}, case=revised_case)
    action("work", {"description": "Second scope complete", "completed": True,
                    "instruction": second_instruction}, case=revised_case)

    def proposed(reference, amount):
        return action("quote", {"reference": reference,
                                "lines": [{"description": "Scope price", "amount": amount}]},
                      case=revised_case)

    def decide(quote, amount, disposition):
        action("decision", {"quote": quote, "reason": "Written decision",
                            "lines": [{"line": 1, "accepted": amount, "disposition": disposition}]},
               case=revised_case)

    initial_quote = proposed("Q-01", "10.00")
    decide(initial_quote, "0.00", "waived")
    next_quote = proposed("Q-02", "20.00")
    before_decision = detail(case=revised_case)["financial"]
    assert before_decision["proposed"] == "20.00"
    assert before_decision["agreed"] == "0.00", before_decision
    assert before_decision["quote_awaiting_decision"] is True
    action("close", close_payload, case=revised_case, error="23514")

    decide(next_quote, "0.00", "waived")
    assert detail(case=revised_case)["financial"]["quote_awaiting_decision"] is False

    # Completion is evaluated by written direction. A later complete record for
    # the second instruction cannot settle the first instruction.
    action("work", {"description": "First scope still needs rework", "completed": False,
                    "instruction": first_instruction}, case=revised_case)
    action("work", {"description": "Second scope passed checks", "completed": True,
                    "instruction": second_instruction}, case=revised_case)
    action("close", close_payload, case=revised_case, error="23514")
    action("work", {"description": "First scope rework complete", "completed": True,
                    "instruction": first_instruction}, case=revised_case)
    action("work", {"description": "Separate factual visit", "completed": False}, case=revised_case)
    action("close", close_payload, case=revised_case)
    assert detail(case=revised_case)["closed"]
    print("PASS: revised pricing and completion independently reconcile before closeout")




if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--auth-migration", type=Path, default=ROOT / "migrations" / "0003_web.sql")
    options = parser.parse_args()
    (ROOT / "target").mkdir(exist_ok=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    with disposable_cluster(environment) as socket:
        run(socket, options.auth_migration)
