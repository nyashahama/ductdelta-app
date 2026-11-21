# DuctDelta

DuctDelta helps mechanical contractors follow a change from the first site observation through work, certification and payment.

A case can start with an instruction, site condition, substitution or revised document. The system keeps authority to work, scope, price, time, certification and cash separate so each person can see what needs to happen next.

## Development

The first implementation is a Rust command line that saves a site observation in PostgreSQL. A project member can browse recent observations and open the original note to see who recorded it and when. Retrying the same capture returns the original record.

On Linux with Rust 1.94.1, PostgreSQL 18 tools and Python 3, run the synthetic demo and integration checks.

```sh
python3 scripts/check_postgres.py --demo
```

The harness creates and removes its own socket-only database clusters. Set `PG_BINDIR` if the PostgreSQL 18 tools are outside `/usr/lib/postgresql/18/bin`. See [capture and verification](docs/capture.md), [the product contract](docs/product.md) and [engineering guidance](AGENTS.md).

Production acceptance requires review with contractors on a completed job through matched payment and a disputed change. Use only synthetic fixtures in this repository.
