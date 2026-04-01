#!/bin/sh
TIMEOUT=120
ELAPSED=0
echo "Waiting for Docker socket..."
until [ -S /var/run/docker.sock ]; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Timeout waiting for Docker socket after $${TIMEOUT}s"
    exit 1
  fi
  echo "Still waiting for socket... ($${ELAPSED}s)"
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo "Docker socket found!"
exec /usr/local/bin/start.sh
