# Issued notice copies

Open a change case and select a recorded notice under **Issued notice copies**. A project member with capture permission and the direction grant can issue a copy while the case is open.

1. Review the agreement, notice deadline and any recorded service instructions. Confirm the recipient and write the text you intend the recipient to see. Only the issuer named in a saved rule can issue versions for that notice. Those versions use the recipient named in that rule.
2. Issue the version and download its UTF-8 text file. The case lists the recipient, issue timestamp and SHA-256. Internal case titles, quotes, finance files and attachment contents are excluded from the document.
3. Use the approved service method to deliver the file or share the recipient link. Copy the link when it is displayed. It expires after seven days, and anyone with it can download that version. The sender can revoke it from the case. A revoked link cannot retrieve a file again. Recipients can keep any file they already downloaded.
4. Record dispatch and acknowledgement through the existing case actions. Issuance, link creation and download do not create dispatch or acknowledgement records. Those case actions reference the recorded notice. Record the supplied copy ID or version in the dispatch reference where appropriate.
5. To issue a revision, open a new draft from the latest copy. The revision identifies the copy it supersedes. Each copy keeps its own bytes and link history.

Run `python3 scripts/check_issued_notices.py` against the disposable PostgreSQL 18 harness. It verifies exact bytes, hash, authorization, replay, supersession, expiry, revocation and dump/restore. Build the frontend with `pnpm --dir frontend build`, set `DUCTDELTA_PLAYWRIGHT_MODULE` to the local Playwright entry point, and run `python3 scripts/check_issued_notice_browser.py` with Chrome installed. Production acceptance requires a counterparty to confirm the format and the agreed service method on a permissioned job.
