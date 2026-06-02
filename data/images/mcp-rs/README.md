# mcp-rs

Rust workspace housing the seven MCP servers that run in the homelab `mcp`
namespace. Each crate produces one binary. `mcp-common` factors out the
streamable-HTTP server boot, bearer-token auth middleware, per-tenant
hashing, NDJSON store, structured logging, and error envelope.

Layout:

- `crates/mcp-common`     — shared library (auth, tenant, store, errors, serve, trace)
- `crates/mcp-<name>`     — one binary per MCP (filesystem, k8s, litellm, memory, prometheus, searxng, time)
- `crates/mcp-integration-tests` — workspace-level black-box tests that spawn each binary

Build one binary in-cluster via the BuildKit job in
`services/mcp-<name>.tf`; build all locally with `cargo build --release`.

Test everything: `cargo test --workspace`.
