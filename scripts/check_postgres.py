#!/usr/bin/env python3
"""Exercise the Rust command line through real logins on a disposable cluster."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("PG_BINDIR", "/usr/lib/postgresql/18/bin")).resolve()
CLI = ROOT / "target" / "debug" / "ductdelta"
PROJECT = "10000000-0000-0000-0000-000000000001"
OTHER_PROJECT = "10000000-0000-0000-0000-000000000002"
SECOND_ORGANIZATION_PROJECT = "10000000-0000-0000-0000-000000000003"
REPORTER = "20000000-0000-0000-0000-000000000001"
DATE = "2026-05-04T08:30:12.123456+02:00"
NOTE = "Supervisor observed a possible duct reroute.\nWritten direction is pending."
LOCATION = "Plantroom A"
PORT = "55491"


@contextmanager
def disposable_cluster(environment):
    with tempfile.TemporaryDirectory(prefix="pg-", dir=ROOT / "target") as work:
        directory = Path(work)
        data = directory / "db"
        socket = directory / "socket"
        socket.mkdir(mode=0o700)
        subprocess.run(
            [BIN / "initdb", "-D", data, "--username=dd_admin", "--no-locale", "--encoding=UTF8",
             "--auth-local=trust", "--auth-host=reject"],
            env=environment, check=True, stdout=subprocess.DEVNULL, timeout=25,
        )
        subprocess.run(
            [BIN / "pg_ctl", "-D", data, "-l", directory / "pg.log",
             "-o", f"-k {shlex.quote(str(socket))} -p {PORT} -c listen_addresses=''", "-w", "start"],
            env=environment, check=True, stdout=subprocess.DEVNULL, timeout=25,
        )
        try:
            yield socket
        finally:
            subprocess.run([BIN / "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"],
                           env=environment, check=True, stdout=subprocess.DEVNULL, timeout=25)


def connection(socket, actor):
    socket_path = str(socket).replace("\\", "\\\\").replace("'", "\\'")
    return f"host='{socket_path}' port={PORT} dbname=postgres user={actor}"


def verify(socket, demo):
    clean_env = {
        key: value for key, value in os.environ.items()
        if not key.startswith("PG") and key != "DUCTDELTA_DATABASE_URL"
    }
    def run(args, *, payload=None, env=None, expected=0):
        result = subprocess.run(
            args, text=True, input=payload, capture_output=True,
            cwd=ROOT, env=clean_env if env is None else env, timeout=25,
        )
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result

    def sql(query, *, actor="dd_admin", at_socket=socket, expected=0):
        args = [BIN / "psql", "-XqAt", "-v", "ON_ERROR_STOP=1"]
        result = run([*args, connection(at_socket, actor)], payload=query, expected=expected)
        return result.stdout.strip()

    def cli(actor, *args, note=None, at_socket=socket, expected=0):
        env = {
            **clean_env,
            "DUCTDELTA_DATABASE_URL": connection(at_socket, actor),
        }
        return run([CLI, *args], payload=note, env=env, expected=expected)

    def capture(actor, operation, note=NOTE, *, expected=0, project=PROJECT, date=DATE, at_socket=socket):
        return cli(actor, "capture", project, operation, date, LOCATION, note=note,
                   expected=expected, at_socket=at_socket)

    def show(actor, observation, *, project=PROJECT, expected=0, at_socket=socket):
        return cli(actor, "show", project, observation, expected=expected, at_socket=at_socket)

    def project_page(actor, project=PROJECT, before=None, *, expected=0, at_socket=socket):
        arguments = ("list", project) if before is None else ("list", project, before)
        return cli(actor, *arguments, expected=expected, at_socket=at_socket)

    def page_ids(result):
        return [
            str(uuid.UUID(line.split(" | ", 1)[0]))
            for line in result.stdout.splitlines()[1:] if not line.startswith("Next page: ")
        ]

    def row_count(project, operation):
        return sql(
            "SELECT count(*) FROM ductdelta.observation "
            f"WHERE project_id = '{project}' AND operation_id = '{operation}';"
        )

    sql((ROOT / "migrations/0001_capture.sql").read_text())
    fixture_roles = (ROOT / "tests/roles.sql").read_text()
    sql(fixture_roles)
    sql((ROOT / "tests/fixture.sql").read_text())

    primary = str(uuid.uuid4())
    created = capture("dd_reporter", primary).stdout.strip()
    assert created, "Capture must return the saved observation's ID."
    assert str(uuid.UUID(created)) == created
    view = show("dd_viewer", created).stdout
    assert f"Actor: {REPORTER}\n" in view and f"Project: {PROJECT}\n" in view
    assert "Observed at: 2026-05-04T06:30:12.123456Z\n" in view
    assert "Recorded at:" in view and view.endswith(f"\n{NOTE}\n")
    assert "Location: Plantroom A\n" in view
    print("PASS: capture and retrieve original text, actor, location and both times")

    sql((ROOT / "migrations/0002_list_observations.sql").read_text())
    existing_page = project_page("dd_viewer")
    assert page_ids(existing_page) == [created]
    assert "Supervisor observed a possible duct reroute. Written direction is pending." in existing_page.stdout
    assert "Next page:" not in existing_page.stdout
    assert "No observations" in project_page("dd_outsider", OTHER_PROJECT).stdout
    outsider_denial = project_page("dd_outsider", expected=1)
    assert "unavailable" in outsider_denial.stderr.lower()
    assert project_page("dd_other_org", expected=1).stderr == outsider_denial.stderr
    assert project_page("dd_viewer", str(uuid.uuid4()), expected=1).stderr == outsider_denial.stderr
    print("PASS: list addresses prior captures after migration and distinguishes empty from unavailable")

    replay = capture("dd_reporter", primary, date="2026-05-04T06:30:12.123456Z")
    assert replay.stdout.strip() == created and row_count(PROJECT, primary) == "1"
    assert show("dd_reporter", created).stdout == view
    distinct = capture("dd_reporter", str(uuid.uuid4())).stdout.strip()
    assert distinct != created
    unknown_op = str(uuid.uuid4())
    unknown = cli("dd_reporter", "capture", PROJECT, unknown_op, "-", note="Time uncertain.").stdout.strip()
    unknown_view = show("dd_viewer", unknown).stdout
    assert "Observed at: unknown\n" in unknown_view and "Location: unspecified\n" in unknown_view
    print("PASS: semantic time replay, independent reports and unknown observed time")

    for actor in ("dd_viewer", "dd_outsider", "dd_other_org"):
        refused = capture(actor, primary, expected=1)
        assert "access" in refused.stderr.lower()
    for actor in ("dd_outsider", "dd_other_org"):
        hidden = show(actor, created, expected=1)
        assert "unavailable" in hidden.stderr.lower()
    show("dd_reporter", created, project=OTHER_PROJECT, expected=1)
    show("dd_reporter", created, project=SECOND_ORGANIZATION_PROJECT, expected=1)
    for statement in [
        "SELECT count(*) FROM ductdelta.observation;",
        "INSERT INTO ductdelta.observation DEFAULT VALUES;",
        "UPDATE ductdelta.observation SET note = 'changed';",
        "DELETE FROM ductdelta.observation;",
    ]:
        sql(statement, actor="dd_reporter", expected=3)
    assert sql(
        f"SET ROLE ductdelta_runtime; SELECT count(*) FROM ductdelta.read_observation('{PROJECT}', '{created}');",
        actor="dd_outsider",
    ) == "0"
    print("PASS: assigned readers, cross-tenant and project isolation, and direct-table denial")

    invalid_op = str(uuid.uuid4())
    capture("dd_reporter", invalid_op, note=" \t\n", expected=1)
    capture("dd_reporter", invalid_op, note="x" * 4001, expected=1)
    capture("dd_reporter", invalid_op, date="2026-05-04T06:30:12.1234567Z", expected=1)
    precise = capture("dd_reporter", invalid_op, date="2026-05-04T06:30:12.1234560001Z", expected=1)
    assert "microsecond" in precise.stderr
    assert row_count(PROJECT, invalid_op) == "0"
    capture("dd_reporter", invalid_op)
    print("PASS: invalid input creates no observation and leaves the retry key usable")

    control_op = str(uuid.uuid4())
    control_note = "First line.\nSecond line with a control character: \x1b"
    control_id = cli("dd_reporter", "capture", PROJECT, control_op, DATE,
                     "Plantroom\nLevel 1", note=control_note).stdout.strip()
    display = show("dd_viewer", control_id).stdout
    assert "\x1b" not in display and "character: \\u{1b}" in display
    assert "Location: Plantroom\\nLevel 1\n" in display
    assert sql(
        f"SELECT position(chr(27) IN note) > 0 FROM ductdelta.observation WHERE id = '{control_id}';"
    ) == "t"
    list_display = project_page("dd_viewer").stdout
    assert "\x1b" not in list_display and "Plantroom\\nLevel 1" in list_display
    long_line = "é" * 120
    long_id = capture("dd_reporter", str(uuid.uuid4()), note=long_line + " retained").stdout.strip()
    listed = next(line for line in project_page("dd_viewer").stdout.splitlines() if line.startswith(long_id))
    assert listed.endswith(long_line + "…")
    assert show("dd_viewer", long_id).stdout.endswith(long_line + " retained\n")
    print("PASS: display escapes terminal control characters and preserves stored evidence")

    # A single statement gives all 100 observations the same recorded_at value.
    sql(
        f"SELECT ductdelta.capture_observation('{OTHER_PROJECT}', gen_random_uuid(), NULL, NULL, "
        "'Synthetic observation ' || sequence) FROM generate_series(1, 100) AS sequence;",
        actor="dd_reporter",
    )
    ordered_ids = sql(
        f"SELECT id FROM ductdelta.observation WHERE project_id = '{OTHER_PROJECT}' "
        "ORDER BY recorded_at DESC, id DESC;"
    ).splitlines()
    assert len(ordered_ids) == 100
    assert sql(
        f"SELECT count(DISTINCT recorded_at) FROM ductdelta.observation WHERE project_id = '{OTHER_PROJECT}';"
    ) == "1"
    first_page = project_page("dd_outsider", OTHER_PROJECT)
    assert page_ids(first_page) == ordered_ids[:50]
    cursor = ordered_ids[49]
    assert first_page.stdout.splitlines()[-1] == f"Next page: {cursor}"
    recent = capture("dd_reporter", str(uuid.uuid4()), project=OTHER_PROJECT).stdout.strip()
    assert page_ids(project_page("dd_outsider", OTHER_PROJECT))[0] == recent
    final_page = project_page("dd_outsider", OTHER_PROJECT, cursor)
    assert page_ids(final_page) == ordered_ids[50:] and "Next page:" not in final_page.stdout
    assert "No observations" in project_page("dd_outsider", OTHER_PROJECT, ordered_ids[-1]).stdout
    foreign_cursor = project_page("dd_reporter", OTHER_PROJECT, created, expected=1)
    assert "page reference" in foreign_cursor.stderr.lower()
    assert project_page("dd_reporter", OTHER_PROJECT, str(uuid.uuid4()), expected=1).stderr == foreign_cursor.stderr
    print("PASS: keyset pages handle tied times, intervening inserts and scoped cursors")

    equal_op = str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=4) as pool:
        repeated = list(pool.map(lambda _: capture("dd_reporter", equal_op).stdout.strip(), range(4)))
    assert len(set(repeated)) == 1 and row_count(PROJECT, equal_op) == "1"

    conflict_op = str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(
            lambda note: subprocess.run(
                [CLI, "capture", PROJECT, conflict_op, DATE, LOCATION], input=note,
                text=True, capture_output=True, timeout=25,
                env={**clean_env, "DUCTDELTA_DATABASE_URL": connection(socket, "dd_reporter")},
            ),
            (NOTE, "A separate account of the event."),
        ))
    assert sorted(result.returncode for result in outcomes) == [0, 1]
    assert "different observation" in next(result.stderr for result in outcomes if result.returncode == 1)
    assert row_count(PROJECT, conflict_op) == "1"
    other = capture("dd_reporter", primary, project=OTHER_PROJECT).stdout.strip()
    assert other != created
    assert capture("dd_other_org", primary, project=SECOND_ORGANIZATION_PROJECT).stdout.strip() != created
    print("PASS: concurrent retries deduplicate, conflicting payloads fail and keys stay scoped")

    sql(f"UPDATE ductdelta.project_member SET permission = 'read' WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}';")
    assert show("dd_reporter", created).stdout == view
    authorized_page = project_page("dd_reporter").stdout
    assert created in authorized_page
    capture("dd_reporter", primary, expected=1)
    sql(f"DELETE FROM ductdelta.project_member WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}';")
    show("dd_reporter", created, expected=1)
    project_page("dd_reporter", expected=1)
    capture("dd_reporter", primary, expected=1)
    assert row_count(PROJECT, primary) == "1"
    print("PASS: downgrade blocks replay and removal blocks reads")

    dump = socket.parent / "capture.dump"
    run([BIN / "pg_dump", "--format=custom", f"--file={dump}", connection(socket, "dd_admin")])
    with disposable_cluster(clean_env) as restored:
        sql("CREATE ROLE ductdelta_owner NOLOGIN; CREATE ROLE ductdelta_runtime NOLOGIN;", at_socket=restored)
        sql(fixture_roles, at_socket=restored)
        run([BIN / "pg_restore", "--exit-on-error", "--dbname", connection(restored, "dd_admin"), dump])
        assert show("dd_viewer", created, at_socket=restored).stdout == view
        assert project_page("dd_viewer", at_socket=restored).stdout == authorized_page
        show("dd_reporter", created, at_socket=restored, expected=1)
        project_page("dd_reporter", at_socket=restored, expected=1)
        show("dd_other_org", created, at_socket=restored, expected=1)
        restored_replay = capture("dd_reporter", primary, project=OTHER_PROJECT, at_socket=restored)
        assert restored_replay.stdout.strip() == other
    print("PASS: fresh-cluster restore preserves observations, revoked access and authorized replay")
    if demo:
        print("\nSynthetic observation\n")
        print(view, end="")
        print("\nProject observations\n")
        print(authorized_page, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="display a synthetic observation after the checks")
    args = parser.parse_args()
    target = ROOT / "target"
    subprocess.run(["cargo", "build", "--locked", "--target-dir", target], cwd=ROOT, check=True)
    version = subprocess.run([BIN / "postgres", "--version"], check=True, text=True, capture_output=True)
    if "(PostgreSQL) 18." not in version.stdout:
        raise SystemExit("Set PG_BINDIR to PostgreSQL 18's bin directory.")

    clean_env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
    with disposable_cluster(clean_env) as socket:
        verify(socket, args.demo)


if __name__ == "__main__":
    main()
