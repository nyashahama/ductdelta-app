# Public marketing pages

| URL | Page |
| --- | --- |
| `/product/` | Product home |
| `/product/workflow/` | Workflow and the first project review |
| `/product/example/` | Fictional change CC-014 and its payment balance |
| `/product/faq/` | Site records, direction, certification and payment |
| `/` | Workspace, company setup and email sign-in |

The approved static export is under `frontend/public/product`. It uses components and styles from [ScrewFast at d95d027](https://github.com/mearashadowfax/ScrewFast/tree/d95d0272b85984193f838bb258ba91599753c1b3). The images illustrate the fictional case. The export includes [ScrewFast and third-party notices](../frontend/public/product/licenses.txt).

Nuxt copies the export into the same release as the workspace. The release script hashes inline script and style blocks from the final HTML. It also hashes the temporary transition rule written by the theme switch. The Rust server uses a separate policy for product pages and serves their content-hashed images, scripts and stylesheet under `/product/_astro/`.

The release script builds the [product theme stylesheet](../frontend/scripts/product-theme.css) from the workspace's compiled neutral and primary colors and its Public Sans fonts. Primary buttons use the workspace's green accent in both themes. The dark theme also uses the workspace surfaces and typography. The browser check compares the rendered dark palette and the primary button colors with the workspace.

Edit the checked-in HTML for copy changes. For layout or behavior changes, rebuild the ScrewFast source and replace the export together with its referenced assets. Import only Preline's accordion, collapse and tabs plugins. Generate Tailwind utilities from the four published pages and those plugins. Keep the product links under `/product/`, workspace actions relative to `/`, and the canonical URLs on `https://ductdelta.com`. The active navigation classes and `aria-current` are set in each HTML page so both slash forms work. Keep the asset filenames tied to their contents.

## Verify a release

```sh
(cd frontend && pnpm install --frozen-lockfile && pnpm run build)
python3 scripts/check_frontend.py
DUCTDELTA_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs python3 scripts/check_browser_setup.py
```

Both Python checks start the Rust server against disposable PostgreSQL and test the built files. The browser check follows the marketing pages to the workspace, exercises the marketing controls with the server's content policy, then tests company setup, invitations and the signed-in dashboard in the offline demo. See [Email sign-in](capture.md#email-sign-in) for the browser check with a loopback mail provider. Set `DUCTDELTA_CHROME` if Chrome is installed away from `/usr/bin/google-chrome`.
