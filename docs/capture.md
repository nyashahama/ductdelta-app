# Site observation capture

DuctDelta records a possible change with a project, reporter, written observation, optional location, and optional time observed. PostgreSQL records the server receipt time. A revised drawing, contract instruction and price can arrive later.

## Run the verification

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
python3 scripts/check_postgres.py --demo
```

The integration harness runs the built Rust executable using real synthetic PostgreSQL logins. It verifies capture and retrieval across processes, listing after a populated database upgrade, pagination, invalid input, project isolation, concurrent retries, access removal and restore into a fresh cluster with independently provisioned roles. Local trust authentication is limited to the private socket directories in this harness.

## Command line

For a dedicated local PostgreSQL 18 instance, a migration administrator applies [the capture migration](../migrations/0001_capture.sql) and [the listing migration](../migrations/0002_list_observations.sql) in order and provisions organizations, projects, actors and memberships. A database with capture already installed applies only the second migration. Give each authenticated login membership in `ductdelta_runtime` and map the login to its actor record. The membership for a single project grants either `read` or `capture`. Runtime users get guarded commands. The migration's non-login owner owns the schema and tables.

Set `DUCTDELTA_DATABASE_URL` to a connection string for the login on a single Unix socket. Use the database's local authentication policy for that login. The command reads observation text from standard input and prints the saved UUID.

```sh
cargo run --locked -- capture PROJECT_UUID OPERATION_UUID 2026-05-04T08:30:00+02:00 'Plantroom A' < note.txt
cargo run --locked -- list PROJECT_UUID
cargo run --locked -- list PROJECT_UUID BEFORE_OBSERVATION_UUID
cargo run --locked -- show PROJECT_UUID OBSERVATION_UUID
```

Use `-` for an unknown observation time. Enter known times in RFC 3339 with an offset and up to six fractional digits. The command displays the time in UTC. The note is UTF-8, nonblank and at most 4,000 characters. Location is optional and at most 120 characters. The displayed text escapes control characters that could alter terminal output. PostgreSQL preserves the original note and location.

Generate an operation UUID once per intended capture. A retry with the same authenticated actor, project and payload returns the same observation ID and leaves the recorded time intact. Different text, location or observed time under that key produces a conflict. Separate operations keep separate reports. A reader can see an observation in an assigned project. Capture and replay both require current capture permission. Missing records and inaccessible records produce the same retrieval result.

The list shows up to 50 records, newest server receipt first, with a one-line note preview. Copy the UUID from the `Next page` line to continue. Listing is live across invocations. Start from the first page again to see observations recorded since opening it. Each request checks project membership and resolves any continuation UUID only inside that project. Use `show` to read the full note.

## Workspace server

Apply the migrations in number order. Build the Nuxt workspace and set `DUCTDELTA_WEB_DIST` to the absolute path of `frontend/.output/public`. Run `ductdelta serve` with a local PostgreSQL login that belongs to `ductdelta_web_runtime`. That role can invoke workspace commands.

New companies and their members enroll in the browser. Company administrators share one-time invitation links privately. Each browser-enrolled user keeps their recovery key in a separate safe place. Recovery replaces both keys and invalidates earlier sessions.

For an upgraded installation, migration 0008 preserves project membership and creates company membership without assigning admin authority. A deployment operator explicitly designates the first administrator of each pre-existing company in `ductdelta.organization_member` after verifying their authority. The operator can issue a temporary sign-in key for a legacy actor with `ductdelta issue-key ACTOR_UUID DISPLAY_NAME` and deliver it privately.

The server binds to loopback at `127.0.0.1:3000` by default. Configure a loopback `DUCTDELTA_LISTEN` and the exact public HTTPS `DUCTDELTA_ORIGIN` for a TLS reverse proxy. Preserve the configured Host header and apply request time and rate limits at the proxy. The local demo uses HTTP on its exact loopback address only.

The server reuses up to 16 PostgreSQL connections per process. Requests that need a database connection receive HTTP 503 while all 16 slots are occupied. A connection lost during capture can leave the result unknown. If you retry the capture, use the original operation UUID and payload. Run `python3 scripts/check_workspace.py` to verify reuse, permission revocation, recovery after a disconnect, and the concurrency limit.
