# Custom Jellyfin image bundling 9p4/jellyfin-plugin-sso for Zitadel SSO.
#
# Jellyfin scans plugins at <DataPath>/plugins which resolves to
# /config/plugins. /config is a PVC mount at runtime, so anything
# baked under /config/... in the image is hidden by the volume.
# Mirror the homeassist Dockerfile pattern: bake plugin files at
# /extras/plugins/SSO-Auth_<version>/, then an init container in
# services/jellyfin.tf copies them into /config/plugins/ on every
# pod start (idempotent).
#
# Plugin runtime config (XML) lives at
# /config/plugins/configurations/SSO-Auth.xml on the PVC and is
# written by the seed Job via POST /sso/OID/Add/<provider>.
#
# Multi-stage so the runtime image doesn't grow a `unzip` package
# or leave the zip in any layer.

ARG BASE_IMAGE=jellyfin/jellyfin:latest

FROM alpine:3.20 AS extractor
ARG SSO_PLUGIN_VERSION
RUN apk add --no-cache unzip wget ca-certificates
RUN wget -O /tmp/sso.zip \
        "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${SSO_PLUGIN_VERSION}/sso-authentication_${SSO_PLUGIN_VERSION}.zip" \
 && mkdir -p "/out/SSO-Auth_${SSO_PLUGIN_VERSION}" \
 && (cd "/out/SSO-Auth_${SSO_PLUGIN_VERSION}" && unzip /tmp/sso.zip) \
 && rm /tmp/sso.zip \
 && test -f "/out/SSO-Auth_${SSO_PLUGIN_VERSION}/SSO-Auth.dll"

FROM ${BASE_IMAGE}
ARG SSO_PLUGIN_VERSION
COPY --from=extractor /out/SSO-Auth_${SSO_PLUGIN_VERSION} \
                      /extras/plugins/SSO-Auth_${SSO_PLUGIN_VERSION}
