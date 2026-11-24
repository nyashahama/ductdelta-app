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

New companies and their members enroll in the browser. Company administrators can email invitations or share one-time links privately. Public HTTPS deployments use email sign-in.

Open Account sessions from the account menu to check active sessions across your company memberships. You can sign out another session or all other sessions and keep the current browser signed in. Run `python3 scripts/check_account_sessions.py` to verify session isolation, revocation, and recovery.

For an upgraded installation, migration 0008 preserves project membership and creates company membership without assigning admin authority. After verifying the member's authority, a deployment operator with `ductdelta_company_bootstrap` can run `ductdelta appoint-first-admin COMPANY_UUID ACTOR_UUID`. This applies once per upgraded company and records the operator and time. If a legacy user lost both keys, an operator can verify their identity and privately issue a temporary enrollment key using `ductdelta issue-key ACTOR_UUID DISPLAY_NAME`.

Company administrators can choose a default invitation lifetime from 1 to 14 days in Company settings. The initial default is 7 days. Saved changes apply to invitations issued afterward. Access history records who made invitation, company role and project access changes from migration 0014 onward. It includes the project creator's first access grant. Run `python3 scripts/check_company_access_history.py` to verify the settings, access history and preservation of a pre-upgrade invitation.

The server binds to loopback at `127.0.0.1:3000` by default. Configure a loopback `DUCTDELTA_LISTEN` and the exact public HTTPS `DUCTDELTA_ORIGIN` for a TLS reverse proxy. Preserve the configured Host header and apply request time and rate limits at the proxy. The local demo uses HTTP on its exact loopback address only.

The server reuses up to 16 PostgreSQL connections per process. Requests that need a database connection receive HTTP 503 while all 16 slots are occupied. A connection lost during capture can leave the result unknown. If you retry the capture, use the original operation UUID and payload. Run `python3 scripts/check_workspace.py` to verify reuse, permission revocation, recovery after a disconnect, and the concurrency limit.

Use the `X-Request-Id` response header to find a request in the server log. HTTPS enables JSON request logs by default. Set `DUCTDELTA_TRACE_REQUESTS=1` to enable them on loopback, or `0` to disable them. Logs include the route template, status and elapsed milliseconds. Run `python3 scripts/check_request_trace.py` to check correlation and log privacy.

### Email sign-in

Users enter their email and an eight-digit code. Each code expires after 10 minutes and can be used once. The verification screen survives a reload of the same tab. Company setup and invitation acceptance complete after email verification. Send emailed invitations to the exact mailbox used by the recipient, including the spelling of the part before `@`. Private invitations can be accepted with a verified work email.

On first sign-in after the upgrade, existing users choose **Use an existing key** and verify their email with their current access or recovery key. This preserves their account and memberships, retires both keys, and ends earlier sessions. If a connection drops after setup or invitation acceptance, request a sign-in code for the same address to recover the account.

After signing in, open **Account security** and generate a recovery code within 10 minutes. Save it outside the sign-in mailbox. A replacement invalidates the previously saved code. To change an address, choose **Change sign-in email** in Account security or **Recover account** on the sign-in screen. Enter the saved code and confirm the new email with a one-time code. DuctDelta keeps the account and memberships, consumes the recovery code, ends earlier sessions, and sends a notice to the previous address. Generate a replacement after changing the address. A linked work account can still sign in through Entra if the mailbox is lost. Keep at least one recovery method available.

Before deploying the web image on HTTPS, apply migration 0021 and configure `DUCTDELTA_RESEND_API_KEY` with sending access, `DUCTDELTA_RESEND_FROM` on a verified domain, and a persistent `DUCTDELTA_INVITE_SIGNING_KEY` of 64 random hex digits. Changing the signing key invalidates pending codes and prevents already queued invitation messages from being sent. Delivered invitation links remain valid until use, cancellation, or expiry.

Once users enroll with email, use an email-capable build for subsequent deployments, including rollbacks.

Company creation is self-service by default. The founder enters their company name, name and email address, then verifies the email to create the company. For a restricted deployment, set `DUCTDELTA_COMPANY_REGISTRATION=code` and set `DUCTDELTA_COMPANY_SETUP_CODE` to 64 random hex digits. A setup-code secret left over from an earlier deployment only applies when code mode is selected. Invited team members join with their own links.

Run `python3 scripts/check_email_sign_in.py` to verify delivery, enrollment, sign-in, migration and reuse against a loopback provider. Add `--browser` with a built frontend, Chromium and `DUCTDELTA_PLAYWRIGHT_MODULE` set to run the browser flow. The offline demo uses keys on loopback. Set `DUCTDELTA_EMAIL_SIGN_IN=1` with a loopback mail provider to exercise email sign-in locally.

### Microsoft Entra sign-in and company MFA

Register a multitenant web application for Microsoft Entra organizational accounts. Add the exact deployed HTTPS URL ending in `/api/account/sso/callback` as a Web redirect URI. Store the application ID in `DUCTDELTA_ENTRA_CLIENT_ID` and its credential in `DUCTDELTA_ENTRA_CLIENT_SECRET`. Apply migration 0022 before configuring a company. The browser signs in through Microsoft using authorization code flow with PKCE. The `openid` and `profile` scopes provide the signed ID token and the user object ID used for the link. Each user first needs an existing DuctDelta company membership and verified sign-in email. [Microsoft ID token claims](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference)

A deployment operator with `ductdelta_company_bootstrap` can configure the company's tenant and link each DuctDelta actor to the verified Entra directory object ID. Look up the IDs through the authorized company roster and tenant directory before linking. Replace the placeholders in these PostgreSQL commands.

```sql
SELECT ductdelta.configure_company_entra('COMPANY_UUID', 'TENANT_UUID');
SELECT ductdelta.link_company_entra('COMPANY_UUID', 'ACTOR_UUID', 'ENTRA_USER_OBJECT_UUID');
```

Share `/?sso=COMPANY_UUID` on the workspace origin. Signed-in members can also choose **Sign in with Microsoft** in Account security. Verify sign-in with a linked member before enabling enforcement. Call `ductdelta.unlink_company_entra(company_uuid, actor_uuid)` to remove an association and revoke its work-account sessions.

For stronger admin and finance sign-in, configure an enabled Entra Conditional Access authentication context that requires MFA or a phishing-resistant authentication strength for the protected users. Configure `acrs` as an optional ID token claim and test that an account outside the policy cannot obtain the required context for privileged access. Link every current company administrator and finance member, then store the matching context in DuctDelta.

```sql
SELECT ductdelta.configure_company_entra('COMPANY_UUID', 'TENANT_UUID', 'c1');
```

A company with enforcement enabled requires a work-account session containing that company's verified context for admin and finance project routes. Add a work-account link for newly granted administrators and finance members before they use those features. Each company requires its own work-account session.

Run `python3 scripts/check_account_security.py` for email change and recovery. Run `python3 scripts/check_company_sign_in.py` against signed loopback Entra tokens. Add `--browser` and configure Chromium and Playwright as above for the browser redirect check. Verify each real Entra tenant's policy and Resend delivery in staging before rollout.

### Invitation email

Each company and each sender account can queue up to 30 email invitations in a rolling hour. A sender's allowance applies across all their companies. Apply migration 0023 before deploying the self-service signup release.

Disable open and click tracking on the sending domain. The message contains the private link. Restrict access to the sender account and its logs. The app distinguishes a queued email from one accepted by Resend. Inbox delivery can be checked through Resend. If a message needs attention, cancel it and create a new invitation or private link.

Set `DUCTDELTA_EMAIL_REPLY_TO` to the monitored support inbox for invitation replies. Invitations and operator activity alerts use the shared DuctDelta layout and include a plain-text body.

Run `python3 scripts/check_invitation_email.py` for retry, isolation, and one-time acceptance with a loopback provider. Set `DUCTDELTA_PLAYWRIGHT_MODULE` and pass `--browser` to send and open an invitation in Chrome with that provider. [Resend sender setup](https://resend.com/docs/dashboard/domains/introduction)

## Railway deployment

Run the web and PostgreSQL 18 containers in the same Railway environment and region. Use a temporary Railway domain for staging and `https://ductdelta.com` as the production origin. Give each environment its own database volume and secrets.

1. Build the private database service using `deploy/postgres.Dockerfile` at the repository root. Mount a volume at `/var/lib/postgresql`. Set `POSTGRES_PASSWORD` and `DUCTDELTA_APP_PASSWORD` to different randomly generated 64-digit hex values. The first initialization applies migrations and creates the restricted `ductdelta_app` login. Use `postgres` as the database administrator and `ductdelta` as the database name.
2. Build the web service from the root `Dockerfile`. Set `DUCTDELTA_DATABASE_URL` to `postgresql://ductdelta_app:PASSWORD@HOST:5432/ductdelta` using references to the database service's `DUCTDELTA_APP_PASSWORD` and `RAILWAY_PRIVATE_DOMAIN`. Set `DUCTDELTA_ORIGIN` to the exact HTTPS origin. Use port 8080 and `/healthz` for the deployment health check. The check requires the migrated schema and the runtime role.
3. Configure the [Resend mailer](#email-sign-in) in each environment with a sending-only key, a verified sender such as `DuctDelta <invites@notify.ductdelta.com>`, and a stable invitation signing key. Keep tracking off. Verify delivery by completing sign-in and accepting a test invitation in the browser.

For later migrations, back up the database and deploy the updated database image first. On an existing volume, the image applies pending migrations over the local socket before accepting network connections. If a migration fails, startup stops. After correcting the failure, restart the database service to retry. Restore a backup in a disposable environment before admitting live customer records.

## Operator activity alerts

Alerts cover new companies, accepted invitations, new projects, and selected change milestones. They contain the event type and UTC time. Invitation links, user and project names, documents, and financial details stay in the workspace.

After migration 0017, the deployment operator can enable alerts over the local database socket. Use an operator-controlled receiving address and a sender on the verified Resend domain. Leave staging unconfigured unless testing with a staging recipient. The app uses its existing Resend configuration.

```sql
INSERT INTO ductdelta.activity_email_settings (recipient, sender)
VALUES (:'recipient', :'sender')
ON CONFLICT (singleton) DO UPDATE
SET recipient = EXCLUDED.recipient, sender = EXCLUDED.sender;
```

Delete the settings row to disable new alerts. Enablement applies to events recorded afterward. Check Railway logs for `activity_email_attempt` with state `accepted` or `needs_attention`. Run `python3 scripts/check_activity_email.py` against the disposable test database.
