#!/usr/bin/env python3
"""Exercise downward certificates and cash allocation through the workspace API."""

from uuid import uuid4

from check_workspace import PROJECT, REPORTER, grant_demo_capabilities, workspace


def verify(server):
    grant_demo_capabilities(server)
    manager = server.sign_in(server.key(REPORTER, "Finance lead"))
    cases = f"/api/projects/{PROJECT}/cases"
    case = server.request(
        cases, "POST", {"operation_id": str(uuid4()), "title": "Corrected certification"}, manager,
    )[0]
    path = f"{cases}/{case['id']}"

    def action(kind, data, expected=200, operation=None):
        return server.request(
            path + "/actions", "POST",
            {"kind": kind, "data": data, "operation_id": operation or str(uuid4())},
            manager, expected=expected,
        )[0]

    def detail():
        return server.request(path, cookie=manager)[0]

    instruction = action("instruction", {"reference": "I-1", "agreement": "MECH-1", "scope": "Fit unit"})
    action("work", {"instruction": instruction["id"], "completed": True, "description": "Unit fitted"})
    quote = action("quote", {"reference": "Q-1", "lines": [{"description": "Fit unit", "amount": "80"}]})
    action("decision", {"quote": quote["id"], "reason": "Agreed", "lines": [
        {"line": 1, "accepted": "80", "disposition": "accepted"},
    ]})
    first = action("certificate", {"reference": "C-1", "cumulative": "100", "withheld": "0", "released": "0"})
    correction = action("certificate", {"reference": "C-2", "cumulative": "80", "withheld": "0", "released": "0",
                                        "predecessor": first["id"], "reason": "Corrected valuation"})
    receipt = action("receipt", {"reference": "R-1", "amount": "80"})
    allocation = {"receipt": receipt["id"], "certificate": first["id"], "amount": "80", "reference": "R-1/C-1"}
    matched = action("allocate", allocation)

    def amounts(**expected):
        financial = detail()["financial"]
        assert {key: financial[key] for key in expected} == expected

    amounts(certified="80.00", payable="80.00", matched="80.00", outstanding="0.00", unallocated="0.00")
    settlement = {"outcome": "settled", "reason": "Valuation and remittance reconciled"}
    close_operation = str(uuid4())
    closed = action("close", settlement, operation=close_operation)
    assert detail()["closed"] is True
    assert action("close", settlement, operation=close_operation) == closed
    evidence = {event["id"]: event for event in detail()["events"]}
    assert evidence[correction["id"]]["data"]["financial_snapshot"]["payable"] == "-20.00"
    snapshot = evidence[closed["id"]]["data"]["financial_snapshot"]
    assert snapshot["outstanding"] == "0.00" and snapshot["certificate_credit_applied"] == "20.00"

    reverse_operation = str(uuid4())
    reversal = {"allocation": matched["id"], "reason": "Remittance reference needs correction"}
    reversed_match = action("reverse_allocation", reversal, operation=reverse_operation)
    assert action("reverse_allocation", reversal, operation=reverse_operation) == reversed_match
    assert detail()["closed"] is False
    amounts(matched="0.00", outstanding="80.00", unallocated="80.00")
    action("close", settlement, expected=422)
    action("allocate", {**allocation, "certificate": correction["id"], "amount": "1"}, expected=422)

    # Give the receipt check enough cash so a failed allocation proves the certificate limit.
    extra = action("receipt", {"reference": "R-2", "amount": "81"})
    too_much = {"receipt": extra["id"], "certificate": first["id"], "amount": "81", "reference": "R-2/C-1"}
    before = detail()
    retry = str(uuid4())
    action("allocate", too_much, expected=422, operation=retry)
    assert detail() == before
    action("allocate", {**too_much, "amount": "80"}, operation=retry)
    amounts(matched="80.00", outstanding="0.00", unallocated="81.00")
    action("close", settlement, expected=422)
    print("PASS: signed correction closes, reversal reopens, and allocation limits preserve excess cash")

    next_case = server.request(
        cases, "POST", {"operation_id": str(uuid4()), "title": "Carry forward certificate credit"}, manager,
    )[0]
    path = f"{cases}/{next_case['id']}"
    action("instruction", {"reference": "I-2", "agreement": "MECH-1", "scope": "Installation phases"})

    def certificate(reference, cumulative, predecessor=None):
        payload = {"reference": reference, "cumulative": cumulative, "withheld": "0", "released": "0"}
        if predecessor:
            payload["predecessor"] = predecessor["id"]
        return action("certificate", payload)

    initial = certificate("C-3", "100")
    bank = action("receipt", {"reference": "R-3", "amount": "160"})
    action("allocate", {"receipt": bank["id"], "certificate": initial["id"], "amount": "100",
                        "reference": "R-3/C-3"})
    credit = certificate("C-4", "80", initial)
    amounts(payable="80.00", matched="100.00", outstanding="-20.00")
    earlier = certificate("C-5", "140", credit)
    later = certificate("C-6", "160", earlier)
    earlier_match = {"receipt": bank["id"], "certificate": earlier["id"], "amount": "40", "reference": "R-3/C-5"}
    action("allocate", {**earlier_match, "amount": "41"}, expected=422)
    action("allocate", {"receipt": bank["id"], "certificate": later["id"], "amount": "20",
                        "reference": "R-3/C-6"})
    action("allocate", earlier_match)
    amounts(payable="160.00", matched="160.00", outstanding="0.00", unallocated="0.00")
    print("PASS: unused credit carries forward to the oldest available certificate")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
