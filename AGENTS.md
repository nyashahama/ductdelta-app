# DuctDelta engineering

- Read [the product contract](docs/product.md) before changing behavior. Keep changes small and commit each coherent increment with a plain, meaningful message.
- Follow the full [Google Rust Style Guide](https://google.github.io/styleguide/rustguide.html) in its application context. Apply platform-specific rules only to their named environments. Use stable Rust, prefer simple ownership and name distinct domain values clearly.
- Use PostgreSQL 18 for project and financial records. Exercise database behavior against disposable Unix-socket-only clusters with synthetic, non-owner runtime identities. Never point the test harness at another database.
- Start behavior changes with a failing test. Verify the application entry point, authorization, retry and recovery boundaries that the change affects. Add dependencies only for a concrete capability.
- Keep the public repository free of customer records, credentials and private research material. Record how to verify each supported path. Keep the completed-job and disputed-change reviews open until the team has evidence.
- For Rust changes run `cargo fmt --all -- --check`, `cargo clippy --all-targets --locked -- -D warnings` and `cargo test --locked`. Run the relevant integration checks for database changes.
