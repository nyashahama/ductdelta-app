# Project notice rules

Open **Notice rules** in the project. A company administrator who is assigned to the project can publish a rule from the signed agreement. Choose a project member with **Direction** access and enter their authority, the agreement and clause, the required recipient and service method, the trigger, and the deadline mechanism. The latest published version applies to new notices for the project.

| Deadline mechanism | Calculation |
| --- | --- |
| Elapsed hours | Add the stated hours to the trigger instant. Clock changes do not change the number of elapsed hours. |
| Calendar days | Find the trigger date in the contract time zone, add the stated calendar days, and use the last instant of that target day. Every calendar date counts. |
| Manual contract deadline | Record the deadline and its basis from the agreement and any calendar or evidence it requires. Use this for business days, holidays, special cutoffs and other terms outside the automatic rules. |

Enter date, time and an explicit UTC offset for the trigger and any manual deadline. The offset identifies the instant. For calendar rules, the configured IANA time zone determines the applicable dates. A local end-of-day cutoff skipped by a time-zone transition requires a manual rule. The timeline records the exact deadline in UTC, the trigger, and the applied rule version. The overview shows deadlines for notices that still need dispatch.

A notice on a configured project requires the current rule version, its agreement and the authorized issuer. If the case already has an agreement, it must match. If the rule changes during entry, refresh and review the rule before submitting again. Notices recorded before a publication keep their original data. Projects without a published rule use the original optional deadline field. Dispatch and acknowledgement are separate records supported by their external references.

Run the HTTP check against a disposable PostgreSQL 18 cluster.

```sh
python3 scripts/check_notice_rules.py
```

For the browser check, build the frontend and use an installed Playwright module and Chromium.

```sh
pnpm --dir frontend run build
DUCTDELTA_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
  DUCTDELTA_CHROME=/absolute/path/to/chromium \
  python3 scripts/check_notice_rules_browser.py
```

Release acceptance requires comparing each configured rule with the signed agreement and checking recipient and service requirements with the project team. See the [product contract](product.md).
