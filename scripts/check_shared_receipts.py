#!/usr/bin/env python3
"""Verify one bank receipt across project cases through non-owner HTTP sessions."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import subprocess
from threading import Barrier
from uuid import uuid4

from check_postgres import BIN, OTHER_PROJECT, connection
from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, SECOND_ORGANIZATION_PROJECT, grant_demo_capabilities, workspace


def verify(server):
    server.sql(
        "INSERT INTO ductdelta.project_workflow_grant "
        "SELECT organization_id, project_id, actor_id, capability "
        "FROM ductdelta.project_member CROSS JOIN "
        "(VALUES ('direction'), ('commercial'), ('finance')) AS grant_types(capability) "
        f"WHERE actor_id IN ('{REPORTER}', '{OTHER_ORGANIZATION}')"
    )
    finance = server.sign_in(server.key(REPORTER, "Finance lead"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company's finance lead"))

    def record(path, kind, data, expected=200, cookie=finance, operation=None):
        return server.request(
            path + "/actions", "POST",
            {"kind": kind, "data": data, "operation_id": operation or str(uuid4())},
            cookie, expected=expected,
        )[0]

    def build_case(project, title, amount, cookie=finance):
        prefix = f"/api/projects/{project}/cases"
        case = server.request(prefix, "POST", {"title": title, "operation_id": str(uuid4())}, cookie)[0]
        path = f"{prefix}/{case['id']}"
        instruction = record(path, "instruction", {
            "reference": "I-1", "agreement": "MECH", "scope": "Install the authorized scope.",
        }, cookie=cookie)
        record(path, "work", {"description": "Complete", "completed": True, "instruction": instruction["id"]}, cookie=cookie)
        quote = record(path, "quote", {"reference": "Q-1", "lines": [{"description": "Agreed work", "amount": amount}]}, cookie=cookie)
        record(path, "decision", {"quote": quote["id"], "reason": "Agreed price", "lines": [
            {"line": 1, "disposition": "accepted", "accepted": amount},
        ]}, cookie=cookie)
        cert = record(path, "certificate", {"reference": "C-1", "cumulative": amount, "withheld": "0", "released": "0"}, cookie=cookie)
        return path, cert["id"]

    def read(path, cookie=finance):
        return server.request(path, cookie=cookie)[0]

    source, source_cert = build_case(PROJECT, "First project case", "60")
    target, target_cert = build_case(OTHER_PROJECT, "Second project case", "40")
    rival, rival_cert = build_case(OTHER_PROJECT, "Other certificate competing for cash", "40")
    foreign, foreign_cert = build_case(SECOND_ORGANIZATION_PROJECT, "Another company", "40", outsider)
    receipt = record(source, "receipt", {"reference": "ACH-001", "amount": "100"})["id"]
    record(source, "allocate", {"reference": "ACH-001/1", "receipt": receipt, "certificate": source_cert, "amount": "60"})
    record(foreign, "allocate", {"reference": "Denied", "receipt": receipt, "certificate": foreign_cert, "amount": "40"},
           expected=404, cookie=outsider)
    assert all(entry["id"] != receipt for entry in read(foreign, outsider)["bank_receipts"])
    assert any(entry["id"] == receipt and entry["available"] == "40.00" for entry in read(target)["bank_receipts"])

    gate = Barrier(2)
    def attempt(path_and_cert):
        path, cert = path_and_cert
        data = {"reference": "ACH-001/2", "receipt": receipt, "certificate": cert, "amount": "40"}
        operation = str(uuid4())
        gate.wait(timeout=5)
        try:
            return path, data, operation, record(path, "allocate", data, operation=operation)
        except AssertionError as error:
            assert error.args[0][2] == 422, error
            return None
    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(attempt, [(target, target_cert), (rival, rival_cert)]))
    assert sum(result is not None for result in results) == 1
    destination, data, operation, allocated = next(result for result in results if result is not None)
    assert record(destination, "allocate", data, operation=operation) == allocated
    record(destination, "allocate", {**data, "amount": "39.99"}, operation=operation, expected=409)
    assert read(source)["financial"]["unallocated"] == "0.00"
    assert read(destination)["financial"]["unallocated"] == "0.00"
    assert read(destination)["financial"]["matched"] == "40.00"
    assert any(entry["id"] == receipt and entry["available"] == "0.00" and entry["reference"] == "ACH-001"
               for entry in read(destination)["bank_receipts"])

    close = {"outcome": "settled", "reason": "Payables reconciled."}
    record(source, "close", close)
    record(destination, "close", close)
    server.sql(
        "DELETE FROM ductdelta.project_workflow_grant "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}' AND capability = 'finance'"
    )
    assert all(entry["id"] != receipt for entry in read(destination)["bank_receipts"])
    record(destination, "allocate", data, operation=operation, expected=404)
    reversal = {"allocation": allocated["id"], "reason": "Remittance correction."}
    record(destination, "reverse_allocation", reversal, expected=404)
    server.sql(
        "INSERT INTO ductdelta.project_workflow_grant "
        "SELECT organization_id, project_id, actor_id, 'finance' FROM ductdelta.project_member "
        f"WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}'"
    )
    record(destination, "reverse_allocation", reversal)
    assert read(source)["closed"] is True
    assert read(source)["financial"]["unallocated"] == "40.00"
    assert read(destination)["closed"] is False
    assert read(destination)["financial"]["outstanding"] == "40.00"
    assert any(entry["id"] == receipt and entry["available"] == "40.00" for entry in read(destination)["bank_receipts"])
    print("PASS: shared receipt balance, concurrent reservation, company and finance isolation, replay and targeted reopening")

    path, cert = build_case(PROJECT, "Certificate competing for different receipts", "50")
    receipts = [record(path, "receipt", {"reference": ref, "amount": "50"})["id"] for ref in ("RR-1", "RR-2")]
    digest = hashlib.sha256(finance.split("=", 1)[1].encode()).hexdigest()
    verify_repeatable_read(server, path.split("/")[-1], cert, receipts, digest)
    assert read(path)["financial"]["matched"] == "50.00"
    print("PASS: a stale repeatable-read writer cannot overpay a certificate with a different receipt")


def verify_repeatable_read(server, case, cert, receipts, digest):
    session = f"decode('{digest}', 'hex')"
    command = [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose",
               connection(server.database_socket, "dd_web")]
    processes = []
    try:
        for receipt in receipts:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, env=server.environment)
            processes.append(process)
            process.stdin.write(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT ductdelta.web_self({session});\n")
            process.stdin.flush()
            assert json.loads(process.stdout.readline())["name"] == "Finance lead"

        for index, (process, receipt) in enumerate(zip(processes, receipts, strict=True)):
            payload = json.dumps({"reference": f"RR-{index + 1}", "receipt": receipt, "certificate": cert, "amount": "50"})
            _, error = process.communicate(
                f"SELECT ductdelta.web_case_action({session}, '{PROJECT}', '{case}', '{uuid4()}', 'allocate', "
                f"'{payload}'::jsonb); COMMIT;\n", timeout=10,
            )
            if index == 0:
                assert process.returncode == 0, error
            else:
                assert process.returncode != 0 and "40001" in error, error
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)



def verify_upgrade():
    migration = "0012_shared_receipts.sql"
    identities = {}

    def seed_legacy(server):
        grant_demo_capabilities(server)
        server.sql("CREATE ROLE dd_legacy_web LOGIN IN ROLE ductdelta_web_runtime")
        # Local fixture login goes through the same session guard the HTTP runtime uses.
        access = "decode(repeat('a', 64), 'hex')"
        session = "decode(repeat('b', 64), 'hex')"
        server.sql("INSERT INTO ductdelta.web_access_key VALUES "
                   f"('{REPORTER}', 'Legacy writer', {access}, statement_timestamp() + interval '1 day')")
        def query(sql):
            return json.loads(server.sql(sql, actor="dd_legacy_web"))

        assert server.sql(f"SELECT ductdelta.web_login({access}, {session})", actor="dd_legacy_web") == "t"
        case = query(f"SELECT ductdelta.web_create_case({session}, '{PROJECT}', '{uuid4()}', 'Legacy case', NULL)")["id"]
        identities["case"] = case

        def record(kind, data, operation=None):
            return query(f"SELECT ductdelta.web_case_action({session}, '{PROJECT}', '{case}', "
                         f"'{operation or uuid4()}', '{kind}', '{json.dumps(data)}')")["id"]

        record("instruction", {"reference": "I-legacy", "agreement": "MECH", "scope": "Install the authorized scope."})
        certificate = record("certificate", {"reference": "C-legacy", "cumulative": "80", "withheld": "0", "released": "0"})
        receipt = record("receipt", {"reference": "BANK-legacy", "amount": "80"})
        identities["receipt"] = receipt
        draft = {"reference": "Legacy part 1", "receipt": receipt, "certificate": certificate, "amount": "25"}
        operation = str(uuid4())
        identities["first_allocation"] = record("allocate", draft, operation)
        identities["replay"] = {"kind": "allocate", "data": draft, "operation_id": operation}
        later = record("allocate", {**draft, "reference": "Legacy part 2", "amount": "10"})
        record("reverse_allocation", {"allocation": later, "reason": "Reference corrected."})

    with workspace(seed_before=migration, before_migration=(migration, seed_legacy)) as server:
        finance = server.sign_in(server.key(REPORTER, "Migrated finance lead"))
        path = f"/api/projects/{PROJECT}/cases/{identities['case']}"
        result = server.request(path, cookie=finance)[0]
        assert result["financial"]["matched"] == "25.00"
        assert result["financial"]["unallocated"] == "55.00"
        assert result["bank_receipts"][0]["id"] == identities["receipt"]
        assert result["bank_receipts"][0]["available"] == "55.00"
        assert result["events"][-1]["kind"] == "reverse_allocation"
        replay, _ = server.request(path + "/actions", "POST", identities["replay"], finance)
        assert replay["id"] == identities["first_allocation"]
        assert server.request(path, cookie=finance)[0] == result
    print("PASS: populated receipt migration preserves original IDs, net cash and operation replay")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
    verify_upgrade()
