#!/bin/bash
# PowerSync replication role. Runs on first Postgres init only (the postgres
# entrypoint skips /docker-entrypoint-initdb.d on subsequent starts when PGDATA
# is non-empty).
#
# The PowerSync role password is read from a Vault-CSI-mounted file at runtime
# so it never lands in the ConfigMap data.
#
# Rotation note: changing random_password.thunderbolt_powersync_role only
# updates the file on disk; the ROLE in Postgres keeps the old password until
# you run ALTER USER ... PASSWORD '...' manually (or wipe PGDATA, which
# re-triggers this init).
#
# See https://docs.powersync.com/configuration/source-db/setup
set -euo pipefail

POWERSYNC_PASS="$(cat /mnt/secrets/thunderbolt_powersync_role_password)"

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --no-password \
  -v powersync_pass="$POWERSYNC_PASS" \
  <<'EOSQL'
CREATE SCHEMA IF NOT EXISTS "powersync";

CREATE ROLE powersync_role WITH REPLICATION BYPASSRLS LOGIN PASSWORD :'powersync_pass';

GRANT USAGE ON SCHEMA powersync TO powersync_role;
GRANT SELECT ON ALL TABLES IN SCHEMA powersync TO powersync_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA powersync GRANT SELECT ON TABLES TO powersync_role;
CREATE PUBLICATION powersync FOR ALL TABLES;
EOSQL
