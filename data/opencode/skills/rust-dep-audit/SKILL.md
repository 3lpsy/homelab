---
name: rust-dep-audit
description: Find unused dependencies (cargo-udeps) and security advisories (cargo-audit) on the current Rust workspace.
---
# rust-dep-audit

Two passes, in order:

1. Unused dependency scan:

       cargo +nightly udeps --workspace

   Reports deps declared in `Cargo.toml` that nothing in the crate
   actually uses. Removing them shrinks compile times and supply-chain
   surface. udeps occasionally false-positives on feature-gated deps —
   verify by checking `#[cfg(feature = "...")]` references before
   deleting.

2. Security advisory scan:

       cargo audit

   Reports CVEs against the resolved `Cargo.lock`. For each finding,
   propose either:
   - bumping the direct dep that pulls the vulnerable version
   - if the vuln is in a transitive only and no patched parent exists,
     a `[patch.crates-io]` override

   Do not silence audits without surfacing why.
