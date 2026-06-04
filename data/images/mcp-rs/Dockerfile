ARG RUST_VERSION=1.95
ARG BIN

FROM lukemathwalker/cargo-chef:latest-rust-${RUST_VERSION}-bookworm AS chef
WORKDIR /app

# crates.io → in-cluster chilled-crates proxy (7-day supply-chain gate). Set as
# Cargo env-config (not a .cargo/config.toml file) so it lands in the `chef` base
# stage and is inherited by BOTH the planner and builder stages — critical
# because `cargo chef cook` downloads every dependency BEFORE the `COPY . .` that
# would bring in a committed config file. CARGO_REGISTRIES_CHILLED_CRATES_INDEX is
# the env form of `[registries.chilled-crates] index`; CARGO_SOURCE_CRATES_IO_
# REPLACE_WITH is `[source.crates-io] replace-with`. Downloaded crates still
# verify against the index checksums (chilled-crates is a transparent mirror).
# NOTE: Cargo.lock is intentionally NUKED (removed from the repo + rm'd in both
# stages below) so cargo re-resolves the whole tree against the proxy every build
# — no frozen <7-day-version failures, at the cost of reproducibility (versions
# can drift; the cooldown bounds them to ≥7-day-old). CRATES_REGISTRY is a build_arg
# from services/mcp-common.tf (tracks var.crates_domain); the build pod resolves
# the FQDN via the crates host_alias in local.buildkit_job_shared.
# See docs/DEP_SAFETY.md.
ARG CRATES_REGISTRY
ENV CARGO_SOURCE_CRATES_IO_REPLACE_WITH=chilled-crates \
    CARGO_REGISTRIES_CHILLED_CRATES_INDEX=${CRATES_REGISTRY}

FROM chef AS planner
COPY . .
# Drop any Cargo.lock that rode in via the build context (a local `cargo build`
# can regenerate it on disk, which the fileset would pull in) so resolution is
# always fresh against the proxy. See docs/DEP_SAFETY.md.
RUN rm -f Cargo.lock && cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG BIN
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN rm -f Cargo.lock && cargo build --release --bin ${BIN}
RUN cp /app/target/release/${BIN} /app/mcp-bin

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /app/mcp-bin /mcp
ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    RUST_LOG=info
EXPOSE 8000
USER nonroot
ENTRYPOINT ["/mcp"]
