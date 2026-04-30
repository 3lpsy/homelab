#!/bin/sh
# Render Syncthing config.xml: bcrypt the GUI password from CSI-mounted Vault
# secret and substitute the __BCRYPT_PASSWORD__ sentinel in the templated config.
set -eu

PASSWORD_FILE="/mnt/secrets/gui_password"
TEMPLATE="/mnt/config-tpl/config.xml"
OUT_DIR="/var/syncthing/config"
OUT="$OUT_DIR/config.xml"

if [ ! -f "$PASSWORD_FILE" ]; then
  echo "missing $PASSWORD_FILE — CSI sync failed?" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# Generate bcrypt hash. Syncthing accepts $2a$/$2b$ bcrypt strings in <password>.
HASH=$(python3 - <<'PY'
import bcrypt, pathlib
p = pathlib.Path("/mnt/secrets/gui_password").read_text().strip().encode()
print(bcrypt.hashpw(p, bcrypt.gensalt(rounds=10)).decode())
PY
)

# sed-substitute. Use a delimiter unlikely to appear in bcrypt output.
sed "s|__BCRYPT_PASSWORD__|$HASH|" "$TEMPLATE" > "$OUT"
chmod 0600 "$OUT"
chown 1000:1000 "$OUT"

# Place the TF-generated stable cert + key so syncthing skips its own
# generate-on-first-start step. The Device ID is derived from the cert,
# so this pinning is what keeps the cluster's identity stable across
# pod restarts. Do NOT overwrite if files already exist with non-zero
# size (defensive — should be a fresh emptyDir in practice).
if [ -s /mnt/secrets/device_cert ] && [ -s /mnt/secrets/device_key ]; then
  cp /mnt/secrets/device_cert "$OUT_DIR/cert.pem"
  cp /mnt/secrets/device_key  "$OUT_DIR/key.pem"
  chmod 0600 "$OUT_DIR/cert.pem" "$OUT_DIR/key.pem"
  echo "stable device cert/key placed"
else
  echo "no device_cert/key in /mnt/secrets — syncthing will self-generate"
fi

# Also chown the parent dir for syncthing's runtime state (cert, key, db).
chown -R 1000:1000 "$OUT_DIR"

echo "config.xml rendered for ${gui_user}"
