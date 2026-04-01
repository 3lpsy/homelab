#!/bin/sh
VAULT_ADDR="http://127.0.0.1:8200"
CHECK_INTERVAL=$${CHECK_INTERVAL:-10}

log () {
  echo "`date '+%Y-%m-%dT%H:%M:%S'` [auto-unseal] $${1}"
}

unseal () {
  RESP=`wget -q -O - --header="Content-Type: application/json" \
    --post-data="{\"key\":\"$${UNSEAL_KEY_1}\"}" \
    "$${VAULT_ADDR}/v1/sys/unseal" 2>&1` || true
  SEALED=`echo "$${RESP}" | grep -o '"sealed":[a-z]*' | cut -d: -f2`
  if [ "$${SEALED}" = "false" ]; then
    log "Unsealed successfully"
    return 0
  fi
  log "Unseal attempted, sealed=$${SEALED}"
  return 1
}

log "Watching seal status (interval=$${CHECK_INTERVAL}s)"

while true; do
  BODY=`wget -q -O - "$${VAULT_ADDR}/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" 2>/dev/null` || true
  if echo "$${BODY}" | grep -q '"sealed":false'; then
    :
  elif echo "$${BODY}" | grep -q '"sealed":true'; then
    log "Sealed — unsealing..."
    unseal || log "Retry next cycle"
  elif echo "$${BODY}" | grep -q '"initialized":false'; then
    log "Not initialized, waiting..."
  else
    log "Unreachable, waiting..."
  fi

  sleep "$${CHECK_INTERVAL}"
done
