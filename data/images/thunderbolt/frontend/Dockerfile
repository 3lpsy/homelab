ARG THUNDERBOLT_REF=main

# Stage 1: Clone + build
# Pinned (was :latest) — match the backend image's bun and keep builds
# reproducible across cold/warm BuildKit cache. Bump deliberately.
FROM oven/bun:1.3.14 AS build

ARG THUNDERBOLT_REF
ARG VITE_THUNDERBOLT_CLOUD_URL="/v1"
# Upstream isSsoMode() (src/lib/auth-mode.ts) matches VITE_AUTH_MODE === 'sso'
# EXACTLY. The legacy "oidc" value left SSO mode OFF, which is the root cause the
# two sed patches below were working around. 'sso' turns on upstream's native
# cookie-session OIDC path (powersync connector bypasses the no-token guard and
# sends credentials:'include'; same for the device/account calls) — matching our
# Zitadel genericOAuth backend. See .env.example: "sso" = enterprise SSO (OIDC).
ARG VITE_AUTH_MODE="sso"
# Skip the consumer /waitlist redirect. isWaitlistBypassed() reads
# VITE_BYPASS_WAITLIST === 'true'. Frontend routing only — backend access stays
# gated by the Zitadel project grant (has_project_check on zitadel_project.git's
# thunderbolt analogue).
ARG VITE_BYPASS_WAITLIST="true"

ENV VITE_THUNDERBOLT_CLOUD_URL=$VITE_THUNDERBOLT_CLOUD_URL
ENV VITE_AUTH_MODE=$VITE_AUTH_MODE
ENV VITE_BYPASS_WAITLIST=$VITE_BYPASS_WAITLIST

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# THUNDERBOLT_REF must be a branch or tag (raw SHAs not supported).
RUN git clone --depth=1 --branch="${THUNDERBOLT_REF}" https://github.com/thunderbird/thunderbolt.git .

# NOTE (2026-05): the two sed patches that used to live here — flipping
# `credentials: 'omit'` → `'include'` in src/api/encryption.ts /
# use-revoke-device.ts / preferences.tsx, and deleting the no-token guard in
# src/db/powersync/connector.ts — are GONE. Upstream main has since (a) moved
# those calls behind the @/lib/http HttpClient abstraction (no raw `credentials:
# 'omit'` left, so the sed matched nothing) and (b) rewritten the connector
# guard to `if (!hadToken && !ssoMode)` with `credentials: ssoMode ? 'include' :
# undefined` (so the old sed pattern no longer matched either). Both are now
# handled natively by VITE_AUTH_MODE="sso" above — isSsoMode()===true bypasses
# the guard and includes the session cookie. Re-add a patch only if a future
# upstream change reintroduces an OIDC-hostile default.

# npm registry → in-cluster Verdaccio proxy (7-day supply-chain gate). build_arg
# from services/thunderbolt.tf (tracks var.npm_domain); the build pod resolves
# the FQDN via the npm host_alias in local.buildkit_job_shared. BUN_CONFIG_REGISTRY
# is bun's native registry knob. We NUKE the upstream lockfile and install WITHOUT
# --frozen-lockfile so bun re-resolves the whole tree against Verdaccio: every
# package (tarballs included) comes through the gate, and it dodges the "pinned
# version <7 days old → hidden by the cooldown → frozen install fails" trap.
# Trade-off: the build is no longer pinned to upstream's exact lock (versions can
# drift between rebuilds; the cooldown still bounds them to ≥7-day-old).
# See docs/DEP_SAFETY.md.
ARG NPM_REGISTRY
ENV BUN_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY}
# BUN_CONFIG_MAX_HTTP_REQUESTS=8 (default ~48-256): throttle bun's parallel
# registry requests so single-threaded Verdaccio + the per-request cooldown filter
# can serve each promptly — unthrottled, the giant packuments saturate it and
# bun's own fetch timeout abandons stragglers ("failed to resolve"). Set INLINE
# (build-scoped), NOT a persistent ENV — this image's runtime is nginx but the
# backend image runs bun and must not be HTTP-throttled at runtime. Tunable up.
RUN rm -f /app/bun.lock /app/bun.lockb && BUN_CONFIG_MAX_HTTP_REQUESTS=8 bun install
RUN bunx vite build && find dist -name '*.map' -delete

# Stage 2: nginx serving SPA + COEP/COOP headers
# Use our own nginx.conf (upstream's proxies /v1/ to http://backend which doesn't
# exist in our cluster — the TLS sidecar handles /v1/* routing instead).
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
