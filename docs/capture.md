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

For an upgraded installation, migration 0008 preserves project membership and creates company membership without assigning admin authority. After verifying the member's authority, a deployment operator with `ductdelta_company_bootstrap` can run `ductdelta appoint-first-admin COMPANY_UUID ACTOR_UUID`. This applies once per upgraded company and records the operator and time. The operator can issue a temporary sign-in key for a legacy actor with `ductdelta issue-key ACTOR_UUID DISPLAY_NAME` and deliver it privately.

Company administrators can choose a default invitation lifetime from 1 to 14 days in Company settings. The initial default is 7 days. Saved changes apply to invitations issued afterward. Access history records who made invitation, company role and project access changes from migration 0014 onward. It includes the project creator's first access grant. Run `python3 scripts/check_company_access_history.py` to verify the settings, access history and preservation of a pre-upgrade invitation.

The server binds to loopback at `127.0.0.1:3000` by default. Configure a loopback `DUCTDELTA_LISTEN` and the exact public HTTPS `DUCTDELTA_ORIGIN` for a TLS reverse proxy. Preserve the configured Host header and apply request time and rate limits at the proxy. The local demo uses HTTP on its exact loopback address only.

The server reuses up to 16 PostgreSQL connections per process. Requests that need a database connection receive HTTP 503 while all 16 slots are occupied. A connection lost during capture can leave the result unknown. If you retry the capture, use the original operation UUID and payload. Run `python3 scripts/check_workspace.py` to verify reuse, permission revocation, recovery after a disconnect, and the concurrency limit.

Use the `X-Request-Id` response header to find a request in the server log. HTTPS enables JSON request logs by default. Set `DUCTDELTA_TRACE_REQUESTS=1` to enable them on loopback, or `0` to disable them. Logs include the route template, status and elapsed milliseconds. Run `python3 scripts/check_request_trace.py` to check correlation and log privacy.

### Invitation email

Company administrators can create a private link or email an invitation through Resend. For email, configure `DUCTDELTA_RESEND_API_KEY` with sending access, `DUCTDELTA_RESEND_FROM` with an address on a verified domain, and `DUCTDELTA_INVITE_SIGNING_KEY` with a persistent 32-byte secret encoded as 64 hex digits. Keep the signing key in the deployment secret store. Changing it prevents already queued messages from being sent. Delivered invitation links remain valid until use, cancellation, or expiry.

Email on a public HTTPS origin requires `DUCTDELTA_COMPANY_SETUP_CODE`, a separate 32-byte random value encoded as 64 hex digits. Share the code privately with the people authorized to create companies. Invited team members can join with their own links.

Disable open and click tracking on the sending domain. The message contains the private link. Restrict access to the sender account and its logs. The app distinguishes a queued email from one accepted by Resend. Inbox delivery can be checked through Resend. If a message needs attention, cancel it and create a new invitation or private link.

Run `python3 scripts/check_invitation_email.py` for retry, isolation, and one-time acceptance with a loopback provider. Set `DUCTDELTA_PLAYWRIGHT_MODULE` and pass `--browser` to send and open an invitation in Chrome with that provider. [Resend sender setup](https://resend.com/docs/dashboard/domains/introduction)
