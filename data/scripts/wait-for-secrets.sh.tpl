#!/bin/sh
TIMEOUT=300
ELAPSED=0
echo "Waiting for ${secret_file} to sync from Vault..."
until [ -f "/mnt/secrets/${secret_file}" ]; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Timeout waiting for secrets after $${TIMEOUT}s"
    exit 1
  fi
  echo "Still waiting... ($${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "Secrets synced successfully!"
