# Verdaccio with the standalone version-age filter baked in.
#
# The built-in @verdaccio/package-filter (minAgeDays) is a Verdaccio 8 plugin
# and is NOT bundled in stable Verdaccio 6.x. To enforce the 7-day cooldown on
# the stable line we install the community plugin verdaccio-plugin-delay-filter
# (works with Verdaccio >= 6.2.0). Config references it as `plugin-delay-filter`
# under `filters:` (see data/registry-proxy/verdaccio.config.yaml).
#
# Bumping: change the base tag or plugin version below; the Dockerfile-hash
# trigger in services/registry-proxy-npm.tf rebuilds. Base pinned by tag (not
# digest) to match the built-image convention here (cf. data/images/otel-
# collector/Dockerfile); 6.7.2 is the current stable 6.x.
FROM verdaccio/verdaccio:6.7.2

LABEL homelab.mirror="verdaccio/verdaccio"
LABEL homelab.upstream-version="6.7.2"

# Verdaccio is installed globally, so a globally-installed sibling plugin
# resolves via its require() path (the documented docker plugin pattern).
USER root
RUN npm install --global verdaccio-plugin-delay-filter@1.2.0
# Back to the unprivileged verdaccio user. uid 10001, primary group root (gid 0)
# — the base image chowns /verdaccio/storage to 10001:root and does `chmod g=u`
# (OpenShift arbitrary-uid pattern), so the runtime group must stay 0. Don't
# pin a different gid here.
USER 10001
