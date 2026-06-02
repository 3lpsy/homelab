---
name: rust-test-narrow
description: Run a single Rust test (or test module) with full output. Prefer this over `cargo test --workspace` when debugging one failure.
---
# rust-test-narrow

Default to the narrowest invocation that reproduces the failure:

    cargo test -p <crate> <test_path> -- --nocapture --test-threads=1

Where:
- `-p <crate>` scopes compilation to one workspace member.
- `<test_path>` is `module::submodule::test_name` (or just `test_name`).
- `--nocapture` shows println/eprintln output (rust-analyzer hides it).
- `--test-threads=1` makes ordering deterministic for flaky timing tests.

Only widen to `cargo test --workspace` when the failure can't be
reproduced narrowly. Wide test runs blow the small-model context
window with unrelated output.
