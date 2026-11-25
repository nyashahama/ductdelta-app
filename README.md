# DuctDelta

DuctDelta helps mechanical contractors follow a change from the first site observation through work, certification and payment.

A case can start with an instruction, site condition, substitution or revised document. The system keeps authority to work, scope, price, time, certification and cash separate so each person can see what needs to happen next.

## Development

On Linux with Node.js 24, pnpm 12.21.0, Rust 1.94.1, PostgreSQL 18 tools and Python 3, build and start the synthetic workspace.

```sh
corepack pnpm@12.21.0 --dir frontend install --frozen-lockfile
corepack pnpm@12.21.0 --dir frontend run build
python3 scripts/check_workspace.py --serve --empty
```

Open the printed loopback URL and choose **Create a company**. The offline demo uses synthetic access and recovery keys. Open **Company settings** to create projects, share single-use invitation links, and grant or revoke access. The harness uses a disposable socket-only database. Set `PG_BINDIR` if the PostgreSQL 18 tools are outside `/usr/lib/postgresql/18/bin`. Use `--serve` alone for the seeded project demo. [Email sign-in and verification](docs/capture.md#email-sign-in)

The workspace uses the [Nuxt UI Dashboard template](https://github.com/nuxt-ui-templates/dashboard/tree/922a0df0e61f4881ca4f6999ab5c755112ae5789). The template's [MIT license](frontend/LICENSE) is included. Rust serves the compiled frontend and the project API from the same origin.

## Public product page

The public landing page opens at `/`. Use **Open workspace** to sign in at `/workspace/`. Previously shared invitations and project links still reach the workspace. [Marketing source and release checks](docs/marketing.md)

After building the frontend, run `python3 scripts/check_frontend.py` to verify the routes, local assets, content security policies and protected workspace API against the local Rust server.

## Supported workflow

Project members can record an observation or a change case before a revised drawing arrives. Assigned roles can record notices, directions, signed quote amounts, performed work, certificates, retention, receipts and closeout. Evidence files retain their original bytes and SHA-256 hashes. Finance files require a finance grant.

The ledger supports manual records in ZAR excluding VAT and allocates one receipt across certificates and projects in the same company when the user has finance access to both projects. [Project notice rules](docs/notice-rules.md) govern new notices when configured. Notice dispatch and receipt are recorded from external references. The full release criteria are in the [product contract](docs/product.md).

Production acceptance requires a completed job through matched payment, a disputed change, and deployment and restore checks. Keep customer records out of the public repository.
