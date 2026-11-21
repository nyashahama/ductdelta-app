# DuctDelta

DuctDelta helps mechanical contractors follow a change from the first site observation through work, certification and payment.

A case can start with an instruction, site condition, substitution or revised document. The system keeps authority to work, scope, price, time, certification and cash separate so each person can see what needs to happen next.

## Development

On Linux with Rust 1.94.1, PostgreSQL 18 tools and Python 3, start the synthetic workspace.

```sh
python3 scripts/check_workspace.py --serve
```

Open the printed loopback URL and sign in with the synthetic access key. The harness uses a disposable socket-only database. Set `PG_BINDIR` if the PostgreSQL 18 tools are outside `/usr/lib/postgresql/18/bin`. The CLI remains available for [capture and verification](docs/capture.md).

The dashboard uses DuctDelta's own markup and styles, with [Tabler's vertical layout](https://docs.tabler.io/ui/layout/page-layouts) and [table patterns](https://docs.tabler.io/ui/components/table) as references.

## Supported workflow

Project members can record an observation or a change case before a revised drawing arrives. Assigned roles can record notices, directions, signed quote amounts, performed work, certificates, retention, receipts and closeout. Evidence files retain their original bytes and SHA-256 hashes. Finance files require a finance grant.

The ledger supports manual records in ZAR excluding VAT and allocates a receipt across certificates within one case. Notice dispatch and receipt are recorded from external references. The full release criteria are in the [product contract](docs/product.md).

Production acceptance requires a completed job through matched payment, a disputed change, and deployment and restore checks. Keep customer records out of the public repository.
