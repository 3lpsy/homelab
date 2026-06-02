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
RUN bun install --frozen-lockfile

# Vendored entrypoint from upstream deploy/docker/backend-entrypoint.sh
RUN cp /app/deploy/docker/backend-entrypoint.sh ./entrypoint.sh && chmod +x ./entrypoint.sh

ENV NODE_ENV=production
ENV PORT=8000
EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
