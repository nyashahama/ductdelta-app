# Public marketing pages

| URL | Page |
| --- | --- |
| `/` | DuctDelta landing page |
| `/product/workflow/` | Workflow and the first project review |
| `/product/example/` | Fictional change CC-014 and its payment balance |
| `/product/faq/` | Site records, direction, certification and payment |
| `/workspace/` | Sign-in, company setup and the dashboard |

The old `/product/` address redirects to the homepage. Workspace query links shared before the move keep their query parameters. The homepage forwards older invitation fragments, and new invitation links point directly to the workspace. API, Entra callback and notice download URLs stay on the same origin.

The private [marketing source repository](https://github.com/nyashahama/ductdelta-marketing) builds the archive in [frontend/marketing](../frontend/marketing/README.md). The application packages the generated public pages, their browser assets and per-page content security policies into the same Railway release as the workspace. The old `/product/_astro/` assets remain available to browsers with the previous pages open. Review hosts serve the marketing pages with a noindex header.

## Verify a release

```sh
(cd frontend && pnpm install --frozen-lockfile && pnpm run build)
python3 scripts/check_frontend.py
export DUCTDELTA_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs
python3 scripts/check_browser_setup.py
python3 scripts/check_email_sign_in.py --browser
python3 scripts/check_invitation_email.py
python3 scripts/check_company_sign_in.py --browser
```

The browser checks exercise company setup, sign-in, new and old invitations, dashboard access, account recovery and the callback through disposable services. The marketing repository's `deploy/check-release.mjs` checks the public HTTP routes and deployment health after the release.
