ARG THUNDERBOLT_REF=main

# Pinned: oven/bun:latest silently jumped to 1.3.14 on a cold-cache rebuild and
# its stricter ESM analyzer surfaced the missing pro/exa.ts export. Bump
# deliberately. Bump pod_spec_sentinel is not needed — the context hash already
# covers this Dockerfile.
FROM oven/bun:1.3.14

ARG THUNDERBOLT_REF

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# THUNDERBOLT_REF must be a branch or tag (raw SHAs not supported).
RUN git clone --depth=1 --branch="${THUNDERBOLT_REF}" https://github.com/thunderbird/thunderbolt.git .

# Overlay: replace Exa-backed Pro search/fetch plugin with our SearXNG-backed
# impl. Same `exaPlugin` export, same routes, same response shapes — routes.ts
# and frontend are unchanged. SEARXNG_URL env var configures the upstream.
COPY exa-override.ts /app/backend/src/pro/exa.ts

WORKDIR /app/backend
# npm registry → in-cluster Verdaccio proxy (7-day supply-chain gate). build_arg
# from services/thunderbolt.tf (tracks var.npm_domain); the build pod resolves
# the FQDN via the npm host_alias in local.buildkit_job_shared. BUN_CONFIG_REGISTRY
# is bun's native registry knob. We NUKE the upstream lockfile(s) and install
# WITHOUT --frozen-lockfile so bun re-resolves the whole tree against Verdaccio:
# every package (tarballs included) comes through the gate, and it dodges the
# "pinned version <7 days old → hidden by the cooldown → frozen install fails"
# trap. Trade-off: no longer pinned to upstream's exact lock (versions can drift;
# the cooldown still bounds them to ≥7-day-old). Both the workspace-root and
# backend locks are removed. See docs/DEP_SAFETY.md.
ARG NPM_REGISTRY
ENV BUN_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY}
# BUN_CONFIG_MAX_HTTP_REQUESTS=8: throttle bun's parallel registry requests so
# single-threaded Verdaccio + the cooldown filter keeps up (see frontend note).
# Set INLINE (build-scoped) — this backend runs bun at RUNTIME and must keep full
# HTTP concurrency for serving, so it must not be a persistent ENV. Tunable up.
RUN rm -f /app/bun.lock /app/bun.lockb /app/backend/bun.lock /app/backend/bun.lockb && BUN_CONFIG_MAX_HTTP_REQUESTS=8 bun install

# Vendored entrypoint from upstream deploy/docker/backend-entrypoint.sh
RUN cp /app/deploy/docker/backend-entrypoint.sh ./entrypoint.sh && chmod +x ./entrypoint.sh

ENV NODE_ENV=production
ENV PORT=8000
EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
