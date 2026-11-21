# Site observation capture

DuctDelta records a possible change with a project, reporter, written observation, optional location, and optional time observed. PostgreSQL records the server receipt time. A revised drawing, contract instruction and price can arrive later.

## Run the verification

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
python3 scripts/check_postgres.py --demo
```

The integration harness runs the built Rust executable using real synthetic PostgreSQL logins. It verifies capture and retrieval across processes, invalid input, project isolation, concurrent retries, access removal and restore into a fresh cluster with independently provisioned roles. Local trust authentication is limited to the private socket directories in this harness.

## Command line

For a dedicated local PostgreSQL 18 instance, a migration administrator applies [the capture migration](../migrations/0001_capture.sql) once and provisions organizations, projects, actors and memberships. Give each authenticated login membership in `ductdelta_runtime` and map the login to its actor record. The membership for a single project grants either `read` or `capture`. Runtime users get guarded commands. The migration's non-login owner owns the schema and tables.

Set `DUCTDELTA_DATABASE_URL` to a connection string for the login on a single Unix socket. Use the database's local authentication policy for that login. The command reads observation text from standard input and prints the saved UUID.

```sh
cargo run --locked -- capture PROJECT_UUID OPERATION_UUID 2026-05-04T08:30:00+02:00 'Plantroom A' < note.txt
cargo run --locked -- show PROJECT_UUID OBSERVATION_UUID
```

Use `-` for an unknown observation time. Enter known times in RFC 3339 with an offset and up to six fractional digits. The command displays the time in UTC. The note is UTF-8, nonblank and at most 4,000 characters. Location is optional and at most 120 characters. The displayed text escapes control characters that could alter terminal output. PostgreSQL preserves the original note and location.

Generate an operation UUID once per intended capture. A retry with the same authenticated actor, project and payload returns the same observation ID and leaves the recorded time intact. Different text, location or observed time under that key produces a conflict. Separate operations keep separate reports. A reader can see an observation in an assigned project. Capture and replay both require current capture permission. Missing records and inaccessible records produce the same retrieval result.

The current interface is a local command line with text evidence. It establishes the capture and access rules for the later web workflow.
