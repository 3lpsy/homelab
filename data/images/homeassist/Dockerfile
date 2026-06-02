# Custom Home Assistant image. Bakes the hass-oidc-auth custom component
# (christiaangoossens/hass-oidc-auth) into a known path. Cannot be placed
# directly under /config/custom_components/ because /config is a PVC mount
# in the cluster — the volume hides any image-baked files at that path.
# Instead the integration files live at /extras/custom_components/auth_oidc
# and an init container in services/homeassist.tf copies them into
# /config/custom_components/ on every pod start (idempotent).
#
# Why custom image vs runtime download: matches the rest of the repo's
# custom-image pattern (data/images/nextcloud, mcp-*, etc) and gives us
# pinned, reproducible HA + integration versions in one artifact. Bumping
# the integration is a one-line ARG change.
#
# IMPORTANT: we fetch the published `hass-oidc-auth.zip` release ASSET
# (not the source-code archive at archive/refs/tags/<v>.tar.gz). The
# release asset includes the pre-built static/style.css; the source
# archive does not, leading to unstyled OIDC welcome/login pages. Per
# the project's FAQ:
#   "If you want to install a release manually, please specifically use
#    the `hass-oidc-auth.zip` (and not the release source code zip),
#    such that you get styling."
# https://github.com/christiaangoossens/hass-oidc-auth/blob/main/docs/faq.md
FROM ghcr.io/home-assistant/home-assistant:stable

ARG HASS_OIDC_AUTH_VERSION=v1.0.2

ADD https://github.com/christiaangoossens/hass-oidc-auth/releases/download/${HASS_OIDC_AUTH_VERSION}/hass-oidc-auth.zip \
    /tmp/hass-oidc-auth.zip

# Zip contents land at the archive root (no custom_components/auth_oidc/
# prefix), so extract directly into the auth_oidc target. Python's stdlib
# zipfile is always present in the HA image — avoids needing apk/apt-get
# for `unzip`.
RUN python3 -c "import zipfile; zipfile.ZipFile('/tmp/hass-oidc-auth.zip').extractall('/extras/custom_components/auth_oidc')" \
 && rm -f /tmp/hass-oidc-auth.zip \
 && test -f /extras/custom_components/auth_oidc/manifest.json \
 && test -f /extras/custom_components/auth_oidc/static/style.css
