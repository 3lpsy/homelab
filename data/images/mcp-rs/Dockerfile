ARG RUST_VERSION=1.95
ARG BIN

FROM lukemathwalker/cargo-chef:latest-rust-${RUST_VERSION}-bookworm AS chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG BIN
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --bin ${BIN}
RUN cp /app/target/release/${BIN} /app/mcp-bin

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /app/mcp-bin /mcp
ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    RUST_LOG=info
EXPOSE 8000
USER nonroot
ENTRYPOINT ["/mcp"]
