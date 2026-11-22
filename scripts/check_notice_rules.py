#!/usr/bin/env python3
"""Exercise notice agreement versions and deadline rules through the real HTTP service."""

from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

from check_postgres import OTHER_PROJECT, SECOND_ORGANIZATION_PROJECT
from check_workspace import OTHER_ORGANIZATION, PROJECT, REPORTER, VIEWER, grant_demo_capabilities, workspace

COMPANY = "30000000-0000-0000-0000-000000000001"
RULE = {
    "agreement": "MECH-02", "clause": "12.3", "issuer_actor_id": REPORTER,
    "authority": "Contract manager", "recipient": "Engineer of record",
    "service_method": "Contract portal", "timezone": "America/New_York",
    "deadline_mode": "calendar_days", "trigger": "Discovery of change", "window": 1,
}


def new_operation():
    return str(uuid4())


def prepare(server):
    grant_demo_capabilities(server)
    server.key(REPORTER, "Site administrator")
    server.key(VIEWER, "Relief recorder")
    server.sql(
        "INSERT INTO ductdelta.organization_member (organization_id, actor_id, role) VALUES "
        f"('{COMPANY}', '{REPORTER}', 'admin'), ('{COMPANY}', '{VIEWER}', 'member') "
        "ON CONFLICT (organization_id, actor_id) DO UPDATE SET role = excluded.role; "
        "INSERT INTO ductdelta.project_workflow_grant (organization_id, project_id, actor_id, capability) VALUES "
        f"('{COMPANY}', '{PROJECT}', '{VIEWER}', 'direction');"
    )


def verify(server, admin, viewer, outsider):
    project = f"/api/projects/{PROJECT}"
    settings = f"{project}/notice-rule"
    cases = f"{project}/cases"
    initial = {"operation_id": new_operation(), "expected_version": 0, "rule": RULE}
    server.request(settings, expected=401)
    server.request(settings, cookie=outsider, expected=404)
    server.request(settings, "POST", initial, viewer, expected=404)
    server.request(f"/api/projects/{SECOND_ORGANIZATION_PROJECT}/notice-rule", "POST", initial, admin, expected=404)
    assert server.request(settings, cookie=viewer)[0]["rule"] is None
    assert server.sql("""
        SELECT
            has_table_privilege(current_user, 'ductdelta.project_notice_rule', 'INSERT'),
            has_function_privilege(current_user,
                'ductdelta.record_other_case_action(bytea,uuid,uuid,uuid,text,jsonb)', 'EXECUTE')
    """, actor="dd_web") == "f|f"

    case = server.request(cases, "POST", {
        "operation_id": new_operation(), "title": "Duct route changed",
    }, admin)[0]
    case_path = f"{cases}/{case['id']}"
    actions = case_path + "/actions"
    legacy = {"operation_id": new_operation(), "kind": "notice", "data": {
        "reference": "Legacy", "agreement": RULE["agreement"], "body": "Old wording.",
    }}
    saved_legacy = server.request(actions, "POST", legacy, admin)[0]

    for key, value in (("timezone", "Not/A_Zone"), ("window", 0), ("issuer_actor_id", OTHER_ORGANIZATION),
                       ("recipient", "Engineer\nAdditional recipient")):
        invalid = {**initial, "rule": {**RULE, key: value}}
        server.request(settings, "POST", invalid, admin, expected=422)
    saved = server.request(settings, "POST", initial, admin)[0]
    assert saved["version"] == 1
    assert saved["issuer_name"] == "Site administrator"
    assert server.request(settings, "POST", initial, admin)[0] == saved
    server.request(settings, "POST", {**initial, "rule": {**RULE, "clause": "12.4"}}, admin, expected=409)
    server.request(settings, "POST", {**initial, "operation_id": new_operation()}, admin, expected=409)
    assert server.request(settings, cookie=viewer)[0]["issuers"] == []
    assert server.request(actions, "POST", legacy, admin)[0] == saved_legacy
    assert server.request(f"/api/projects/{OTHER_PROJECT}/notice-rule", cookie=admin)[0]["rule"] is None

    notice = {"operation_id": new_operation(), "kind": "notice", "data": {
        "reference": "N-001", "agreement": RULE["agreement"], "body": "Duct route rerouted.",
        "notice_rule_version": 1, "trigger_at": "2026-03-07T23:59:59-05:00",
    }}

    def post(**data):
        return server.request(actions, "POST", {**notice, "data": {**notice["data"], **data}}, admin, expected=422)

    server.request(actions, "POST", {**legacy, "operation_id": new_operation()}, admin, expected=409)
    server.request(actions, "POST", notice, viewer, expected=404)
    post(agreement="Wrong agreement")
    post(trigger_at="2026-03-07T23:59:59")
    post(due_at="2026-03-09T03:59:58Z")
    post(reference="Invalid\nreference")
    recorded = server.request(actions, "POST", notice, admin)[0]
    events = server.request(case_path, cookie=viewer)[0]["events"]
    assert "notice_rule" not in events[0]["data"]
    assert events[-1]["data"]["notice_rule"] == saved
    assert events[-1]["data"]["due_at"] == "2026-03-09T03:59:59.999999Z"
    assert events[-1]["data"]["trigger_at"] == notice["data"]["trigger_at"]
    current = server.request(settings, "POST", {
        "operation_id": new_operation(), "expected_version": 1, "rule": {
            **RULE, "clause": "12.4", "deadline_mode": "elapsed_hours", "window": 24,
        },
    }, admin)[0]
    assert current["version"] == 2
    assert server.request(settings, "POST", initial, admin)[0] == saved
    assert server.request(actions, "POST", notice, admin)[0] == recorded
    server.request(actions, "POST", {**notice, "data": {**notice["data"], "body": "Different"}}, admin, expected=409)
    second = {**notice, "operation_id": new_operation(),
              "data": {**notice["data"], "reference": "N-002", "trigger_at": "2026-03-08T01:30:00-05:00"}}
    server.request(actions, "POST", second, admin, expected=409)
    server.request(actions, "POST", {**second, "data": {**second["data"], "notice_rule_version": 2}}, admin)
    events = server.request(case_path, cookie=admin)[0]["events"]
    assert events[-2]["data"]["notice_rule"]["version"] == 1
    assert events[-1]["data"]["due_at"] == "2026-03-09T06:30:00.000000Z"

    manual_rule = {key: value for key, value in RULE.items() if key != "window"}
    manual = server.request(settings, "POST", {
        "operation_id": new_operation(), "expected_version": 2, "rule": {
            **manual_rule, "deadline_mode": "manual",
            "manual_instructions": "Apply the agreed shutdown calendar.",
        },
    }, admin)[0]
    assert manual["version"] == 3
    third = {**notice, "operation_id": new_operation(), "data": {**notice["data"],
             "reference": "N-003", "notice_rule_version": 3, "due_at": "2026-03-10T12:00:00+02:00"}}
    server.request(actions, "POST", third, admin, expected=422)
    third["data"]["deadline_basis"] = "Confirmed agreed shutdown date."
    server.request(actions, "POST", third, admin)
    event = server.request(case_path, cookie=admin)[0]["events"][-1]
    assert event["data"]["notice_rule"] == manual
    assert event["data"]["due_at"] == "2026-03-10T10:00:00.000000Z"
    overview = server.request(f"{project}/overview?days=14", cookie=viewer)[0]
    assert {"N-001", "N-002", "N-003"} <= {notice["reference"] for notice in overview["notices"]}

    def publish_version(clause):
        payload = {"operation_id": new_operation(), "expected_version": 3, "rule": {**RULE, "clause": clause}}
        try:
            return server.request(settings, "POST", payload, admin)[0]["version"]
        except AssertionError as result:
            assert result.args[0][2] == 409, result
            return None

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(publish_version, ["12.5", "12.6"]))
    assert results.count(4) == results.count(None) == 1
    assert server.request(settings, cookie=viewer)[0]["rule"]["version"] == 4
    server.request(settings, "POST", {
        "operation_id": new_operation(), "expected_version": 4, "rule": {**RULE, "timezone": "Pacific/Apia"},
    }, admin)
    skipped_cutoff = {"operation_id": new_operation(), "kind": "notice", "data": {
        **notice["data"], "reference": "Skipped cutoff", "notice_rule_version": 5,
        "trigger_at": "2011-12-29T12:00:00-10:00",
    }}
    message = server.request(actions, "POST", skipped_cutoff, admin, expected=422)[0]["message"]
    assert "local cutoff does not exist" in message
    print("PASS: project authorization, locked rule publication, DST boundaries, manual deadlines, overview and retries")


if __name__ == "__main__":
    with workspace() as server:
        prepare(server)
        verify(server,
               server.sign_in(server.key(REPORTER, "Site administrator")),
               server.sign_in(server.key(VIEWER, "Relief recorder")),
               server.sign_in(server.key(OTHER_ORGANIZATION, "Other company")))
