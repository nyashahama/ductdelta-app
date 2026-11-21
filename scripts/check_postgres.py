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
    print("PASS: display escapes terminal control characters and preserves stored evidence")

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
    capture("dd_reporter", primary, expected=1)
    sql(f"DELETE FROM ductdelta.project_member WHERE project_id = '{PROJECT}' AND actor_id = '{REPORTER}';")
    show("dd_reporter", created, expected=1)
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
        show("dd_reporter", created, at_socket=restored, expected=1)
        show("dd_other_org", created, at_socket=restored, expected=1)
        restored_replay = capture("dd_reporter", primary, project=OTHER_PROJECT, at_socket=restored)
        assert restored_replay.stdout.strip() == other
    print("PASS: fresh-cluster restore preserves observations, revoked access and authorized replay")
    if demo:
        print("\nSynthetic observation\n")
        print(view, end="")


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
