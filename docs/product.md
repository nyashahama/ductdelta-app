# DuctDelta product contract

The contractor can record a possible change even when documents, instructions and pricing are incomplete. Keep each source and decision traceable so the site and commercial teams can act on what is known.

| Delivery | Outcome |
| --- | --- |
| Capture | Save what a site user observed, where and when, and who recorded it. Let the assigned project team retrieve it. Preserve a manual path when a document is missing or unreadable. |
| Direction and notice | Record who can instruct work and which agreement and scope it covers. Keep exact issued documents, dispatch, receipt and authority as separate facts. |
| Scope, work and price | Trace awarded scope, additions, credits, provisional work and measured progress. Distinguish permission to proceed, agreed work, price and time. |
| Certification and collections | Keep signed certificate deltas, adjustments, retention and receipt allocations. Preserve outstanding, disputed and unallocated amounts and their evidence. |
| Closeout | Verify the work and financial resolution, keep earlier issues accessible, and reopen the affected balance when later evidence changes it. |

The application will use exact decimal money, explicit currency and tax basis when it reaches pricing. Record agreement, authority and notice rules per project. Keep private costs and bank evidence out of recipient copies. Export the exact issued version and test whether project counterparties will accept it.

## Change follow-ups

Open **Overview → Change follow-ups** to review open cases. Notices due within the dashboard's seven-day window come first. Commercial and finance users see agreed value still to certify, net certified balance, retention held and quote decisions. Where a payment is outstanding, the list shows references for up to three unpaid certificates after credits and matched receipts. The amounts come from recorded case activity and use ZAR excluding VAT. Check the payment terms before treating a balance as overdue.

Select a case in the queue to see its actions and evidence. Use **Open case** to record an action, or open the source observation and download files from the dashboard. The dashboard uses the same access rules as the case. Finance-only files and unmatched cash stay within the finance grant. Download an issued notice version to send via the project's agreed service method and record dispatch on the case. A revised notice follow-up does not reuse the original deadline once a dispatch is recorded. Run `python3 scripts/check_overview.py` against the disposable PostgreSQL workspace to verify the list.

## Production acceptance

Review a permissioned completed job with the actual agreement, instructions, quote, certificates and matched receipts. Separately review a disputed change with its original submissions, disputed lines, decisions and unresolved or settled amounts. Confirm each handoff with the responsible people.

Before release, verify deployed tenant and recipient controls, retention and privacy arrangements, field-device behavior, rejection and recovery paths, exact money and issued copies, and backup restore with the referenced files. Review authority and notice settings against the signed agreement. Record the evidence and the product’s supported configurations.
