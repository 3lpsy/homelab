#!/bin/sh
# Render the Keycloak realm import JSON from a placeholder template.
#
# Reads /template/thunderbolt-realm.json (mounted from a ConfigMap that holds
# a placeholder JSON) and substitutes the four ${VAR} markers from env vars
# sourced from the Vault-CSI-synced thunderbolt-secrets Secret. Writes the
# fully rendered file to /rendered/thunderbolt-realm.json (emptyDir) which
# the main keycloak container imports via --import-realm.
#
# Why: keeps oidc_client_secret + seed_user_password out of the ConfigMap
# (and therefore out of Velero backup tarballs in S3).
#
# Safety: random_password resources backing both secrets use special=false,
# so values are alphanumeric only and can't break the | -delimited sed
# replacement. The escaped \${VAR} on the LHS prevents the shell from
# expanding the placeholder before sed sees it; the unescaped ${VAR} on
# the RHS is shell-expanded to the actual env-var value.
set -eu

sed \
  -e "s|\${OIDC_CLIENT_SECRET}|${OIDC_CLIENT_SECRET}|g" \
  -e "s|\${SEED_USER_PASSWORD}|${SEED_USER_PASSWORD}|g" \
  -e "s|\${ADMIN_EMAIL}|${ADMIN_EMAIL}|g" \
  -e "s|\${PUBLIC_URL}|${PUBLIC_URL}|g" \
  /template/thunderbolt-realm.json > /rendered/thunderbolt-realm.json
