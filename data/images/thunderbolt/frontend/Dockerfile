ARG THUNDERBOLT_REF=main

# Stage 1: Clone + build
FROM oven/bun:latest AS build

ARG THUNDERBOLT_REF
ARG VITE_THUNDERBOLT_CLOUD_URL="/v1"
ARG VITE_AUTH_MODE="oidc"

ENV VITE_THUNDERBOLT_CLOUD_URL=$VITE_THUNDERBOLT_CLOUD_URL
ENV VITE_AUTH_MODE=$VITE_AUTH_MODE

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone --depth=1 --branch="${THUNDERBOLT_REF}" https://github.com/thunderbird/thunderbolt.git .

# Patch: in AUTH_MODE=oidc the Keycloak login ends in a 302 the SPA never
# observes via fetch, so better-auth's `set-auth-token` header is lost and
# localStorage's bearer token stays empty. Per upstream's own OIDC doc
# (backend/docs/oidc-local-dev.md) OIDC mode is designed to authenticate
# via the session cookie, but these three files (added later in PR #525
# without OIDC in mind) hardcode `credentials: 'omit'`. Flip them to
# `'include'` so the cookie authenticates the device/revoke/delete calls.
# Tauri keeps sending Authorization headers via its own HTTP transport.
RUN sed -i "s/credentials: 'omit'/credentials: 'include'/g" \
      src/api/encryption.ts \
      src/hooks/use-revoke-device.ts \
      src/settings/preferences.tsx \
 && ! grep -q "credentials: 'omit'" \
      src/api/encryption.ts \
      src/hooks/use-revoke-device.ts \
      src/settings/preferences.tsx

# Companion patch: ThunderboltConnector short-circuits fetchCredentials with
# `return null` when localStorage has no bearer token. In OIDC mode the bearer
# never lands in localStorage (same root cause as the patch above), so
# PowerSync never asks for a token and sync hangs at "Initial sync timed out".
# Drop the guard — the fetch() to /powersync/token runs same-origin so the
# session cookie is attached automatically and the backend auth macro accepts
# either auth method. Keep `const hadToken` in place: downstream telemetry
# (`had_token: hadToken`) still references it.
RUN sed -i '/if (!hadToken) {/,/^      }$/d' \
      src/db/powersync/connector.ts \
 && ! grep -q 'if (!hadToken)' src/db/powersync/connector.ts

RUN bun install --frozen-lockfile
RUN bunx vite build && find dist -name '*.map' -delete

# Stage 2: nginx serving SPA + COEP/COOP headers
# Use our own nginx.conf (upstream's proxies /v1/ to http://backend which doesn't
# exist in our cluster — the TLS sidecar handles /v1/* routing instead).
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
