#!/bin/bash
# PowerSync replication role + Keycloak DB. Runs on first Postgres init only
# (the postgres entrypoint skips /docker-entrypoint-initdb.d on subsequent
# starts when PGDATA is non-empty).
#
# Passwords are read from Vault-CSI-mounted files at runtime so they never
# land in the ConfigMap data — keeps the credentials out of Velero backup
# tarballs.
#
# Rotation note: changing random_password.thunderbolt_{powersync_role,
# keycloak_db} only updates the file on disk; the ROLE/USER in Postgres
# keeps the old password until you run ALTER USER ... PASSWORD '...'
# manually (or wipe PGDATA, which would re-trigger this init).
#
# See https://docs.powersync.com/configuration/source-db/setup
set -euo pipefail

POWERSYNC_PASS="$(cat /mnt/secrets/thunderbolt_powersync_role_password)"
KEYCLOAK_PASS="$(cat /mnt/secrets/thunderbolt_keycloak_db_password)"

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --no-password \
  -v powersync_pass="$POWERSYNC_PASS" \
  -v keycloak_pass="$KEYCLOAK_PASS" \
  <<'EOSQL'
CREATE SCHEMA IF NOT EXISTS "powersync";

CREATE ROLE powersync_role WITH REPLICATION BYPASSRLS LOGIN PASSWORD :'powersync_pass';

GRANT USAGE ON SCHEMA powersync TO powersync_role;
GRANT SELECT ON ALL TABLES IN SCHEMA powersync TO powersync_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA powersync GRANT SELECT ON TABLES TO powersync_role;
CREATE PUBLICATION powersync FOR ALL TABLES;

CREATE USER keycloak WITH PASSWORD :'keycloak_pass';
CREATE DATABASE keycloak OWNER keycloak;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOSQL
