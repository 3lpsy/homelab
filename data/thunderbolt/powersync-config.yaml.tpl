# Drop per-request info logs that leak user_id / client_id / rid on every
# sync tick. `warn` keeps backend errors visible.
logger:
  level: warn

replication:
  connections:
    - type: postgresql
      uri: postgresql://powersync_role:${powersync_role_password}@thunderbolt-postgres:5432/thunderbolt
      sslmode: disable

storage:
  type: mongodb
  uri: mongodb://thunderbolt-mongo:27017/powersync

port: 8080

sync_rules:
  content: |
    bucket_definitions:
      user_data:
        parameters: SELECT request.user_id() as user_id
        data:
          - SELECT * FROM powersync.settings WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.chat_threads WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.chat_messages WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.tasks WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.models WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.mcp_servers WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.prompts WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.triggers WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.modes WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.model_profiles WHERE user_id = bucket.user_id
          - SELECT * FROM powersync.devices WHERE user_id = bucket.user_id

client_auth:
  supabase: false
  audience: ['powersync-enterprise', 'powersync']
  jwks:
    keys:
      - kty: oct
        k: ${powersync_jwt_secret_b64}
        alg: HS256
        kid: ${powersync_jwt_kid}
  telemetry:
    disable_telemetry_sharing: true
