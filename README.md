# DuctDelta

DuctDelta helps mechanical contractors follow a change from the first site observation through work, certification and payment.

A case can start with an instruction, site condition, substitution or revised document. The system keeps authority to work, scope, price, time, certification and cash separate so each person can see what needs to happen next.

## Development

The backend uses Rust and PostgreSQL. The first delivery starts with recording and retrieving a site observation under project-scoped access. See [the product contract](docs/product.md) and [engineering guidance](AGENTS.md).

Production acceptance requires review with contractors on a completed job through matched payment and a disputed change. Use only synthetic fixtures in this repository.
