#!/usr/bin/env python3
"""Generate /etc/nginx/htpasswd from CSI-mounted Vault secrets.

The SecretProviderClass syncs `password_<user>` keys into a K8s secret;
each is mounted as a file under /mnt/secrets/. We bcrypt each value and
emit a single `<user>:<bcrypt>` line per user.
"""
import bcrypt
import os
import pathlib
import sys

SECRETS_DIR = pathlib.Path("/mnt/secrets")
OUT_PATH = pathlib.Path("/htpasswd/htpasswd")
PREFIX = "password_"


def main() -> int:
    if not SECRETS_DIR.is_dir():
        print(f"missing {SECRETS_DIR}", file=sys.stderr)
        return 1

    lines = []
    for entry in sorted(SECRETS_DIR.iterdir()):
        if not entry.name.startswith(PREFIX):
            continue
        if not entry.is_file():
            continue
        user = entry.name[len(PREFIX):]
        password = entry.read_text().strip().encode()
        if not password:
            continue
        h = bcrypt.hashpw(password, bcrypt.gensalt(rounds=10)).decode()
        lines.append(f"{user}:{h}")

    if not lines:
        print("no users found in /mnt/secrets — refusing to write empty htpasswd", file=sys.stderr)
        return 1

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text("\n".join(lines) + "\n")
    OUT_PATH.chmod(0o644)
    print(f"htpasswd written: {len(lines)} user(s) -> {OUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
