-- PowerSync replication role and publication (runs on first Postgres init only).
-- See https://docs.powersync.com/configuration/source-db/setup

CREATE SCHEMA IF NOT EXISTS "powersync";

CREATE ROLE powersync_role WITH REPLICATION BYPASSRLS LOGIN PASSWORD '${powersync_role_password}';

GRANT USAGE ON SCHEMA powersync TO powersync_role;
GRANT SELECT ON ALL TABLES IN SCHEMA powersync TO powersync_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA powersync GRANT SELECT ON TABLES TO powersync_role;
CREATE PUBLICATION powersync FOR ALL TABLES;

-- Keycloak database + user
CREATE USER keycloak WITH PASSWORD '${keycloak_db_password}';
CREATE DATABASE keycloak OWNER keycloak;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
