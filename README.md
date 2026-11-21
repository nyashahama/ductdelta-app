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

Production acceptance requires review with contractors on a completed job through matched payment and a disputed change. Use only synthetic fixtures in this repository.
