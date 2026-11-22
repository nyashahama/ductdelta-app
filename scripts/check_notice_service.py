#!/usr/bin/env python3
"""Verify explicit service of an immutable notice version through the case command."""

from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

from check_issued_notices import seed_notice
from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER, grant_demo_capabilities, workspace


def verify(server):
    reporter = server.sign_in(server.key(REPORTER, "Site reporter"))
    viewer = server.sign_in(server.key(VIEWER, "Project viewer"))
    outsider = server.sign_in(server.key(OTHER_ORGANIZATION, "Other company"))
    grant_demo_capabilities(server)
    detail, notice = seed_notice(server, reporter)
    other_detail, other_notice = seed_notice(server, reporter)

    def action(kind, inputs):
        return {"operation_id": str(uuid4()), "kind": kind, "data": inputs}

    def record(command, cookie=reporter, expected=200, *, case=detail):
        return server.request(f"{case}/actions", "POST", command, cookie, expected=expected)[0]

    def issue(at, target, predecessor=None):
        draft = {
            "operation_id": str(uuid4()), "recipient": "Engineer of record", "message": "Reviewed copy",
            "supersedes": predecessor,
        }
        return server.request(f"{at}/notices/{target}/copies", "POST", draft, reporter)[0]

    legacy_inputs = {"notice": notice, "reference": "Historic dispatch"}
    legacy_command = action("notice_dispatch", legacy_inputs)
    legacy = record(legacy_command)
    legacy_receipt = action("notice_receipt", {"notice": notice, "reference": "Historic acknowledgement"})
    saved_legacy_receipt = record(legacy_receipt)
    first = issue(detail, notice)
    other = issue(other_detail, other_notice)
    same_case_notice = record(action("notice", {
        "reference": "N-02", "agreement": "MECH-01", "body": "Different notice in this case",
    }))["id"]
    same_case_copy = issue(detail, same_case_notice)
    assert record(legacy_command) == legacy
    assert record(legacy_receipt) == saved_legacy_receipt
    record(action("notice_dispatch", {**legacy_inputs, "reference": "Portal but no copy"}), expected=422)
    record(action("notice_receipt", {**legacy_inputs, "reference": "Unlinked acknowledgement"}), expected=422)
    legacy_ack = action("notice_receipt", {
        "notice": notice, "reference": "Legacy acknowledgement", "dispatch": legacy["id"],
    })
    record(legacy_ack)

    inputs = {
        "notice": notice, "reference": "Portal upload 1", "issued_copy": first["id"],
        "recipient": first["recipient"], "service_method": "Contract portal",
    }
    record(action("notice_dispatch", {**inputs, "issued_copy": other["id"]}), expected=404)
    record(action("notice_dispatch", {**inputs, "issued_copy": same_case_copy["id"]}), expected=404)
    record(action("notice_dispatch", {**inputs, "recipient": "Different recipient"}), expected=422)
    record(action("notice_dispatch", {**inputs, "copy": {"sha256": "forged"}}), expected=422)
    record(action("notice_dispatch", inputs), cookie=viewer, expected=404)
    record(action("notice_dispatch", inputs), cookie=outsider, expected=404)

    dispatch = action("notice_dispatch", inputs)
    with ThreadPoolExecutor(max_workers=2) as workers:
        recorded, replay = workers.map(lambda _: record(dispatch), range(2))
    assert recorded == replay
    record({**dispatch, "data": {**inputs, "reference": "Changed request"}}, expected=409)
    first_ack = record(action("notice_receipt", {
        "notice": notice, "reference": "Engineer receipt 1", "dispatch": recorded["id"],
    }))
    record(action("notice_receipt", {
        "notice": other_notice, "reference": "Wrong case", "dispatch": recorded["id"],
    }), expected=404, case=other_detail)

    second = issue(detail, notice, first["id"])
    record(action("notice_dispatch", {
        **inputs, "notice": same_case_notice, "issued_copy": same_case_copy["id"],
        "corrects_dispatch": recorded["id"],
    }), expected=404)
    correction = record(action("notice_dispatch", {
        **inputs, "reference": "Portal upload 2 corrected", "issued_copy": second["id"],
        "corrects_dispatch": recorded["id"],
    }))
    second_ack = record(action("notice_receipt", {
        "notice": notice, "reference": "Engineer receipt 2", "dispatch": correction["id"],
    }))
    reader = server.request(detail, cookie=viewer)[0]
    assert {copy["id"] for copy in reader["issued_notice_copies"]} == {first["id"], second["id"], same_case_copy["id"]}
    assert server.sql("""SELECT has_function_privilege(current_user,
        'ductdelta.record_other_service_case_action(bytea,uuid,uuid,uuid,text,jsonb)', 'EXECUTE')""",
        actor="dd_web") == "f"
    by_id = {event["id"]: event["data"] for event in reader["events"]}
    assert by_id[legacy["id"]] == legacy_inputs
    assert by_id[correction["id"]]["corrects_dispatch"] == recorded["id"]
    for dispatch_id, acknowledgement_id, copy in (
        (recorded["id"], first_ack["id"], first), (correction["id"], second_ack["id"], second),
    ):
        expected = {field: copy[field] for field in ("id", "version", "recipient", "sha256")}
        assert by_id[dispatch_id]["copy"] == expected
        assert by_id[acknowledgement_id]["copy"] == expected
        assert by_id[acknowledgement_id]["dispatch"] == dispatch_id
    print("PASS: explicit versioned dispatch, immutable recipient and hash, scoped acknowledgement, correction and retries")


if __name__ == "__main__":
    with workspace() as server:
        verify(server)
