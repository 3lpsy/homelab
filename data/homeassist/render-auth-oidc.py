#!/usr/bin/env python3
"""Render the auth_oidc config for hass-oidc-auth.

Idempotent. Re-run on every pod start by an init container in services/
homeassist.tf. Two outputs:

  1. /config/auth_oidc.yaml — the actual auth_oidc block with literal
     client_id + client_secret from /mnt/secrets (Vault-backed via CSI).
     Rewritten on every run so Vault rotation propagates.

  2. /config/configuration.yaml — patched in two passes:
       a) Strip any pre-existing top-level `auth_oidc:` block (e.g. an
          old inline !env_var-based attempt that the user's pod has from
          a manual append). Catches anything from the start of the block
          up to (but not including) the next top-level YAML key or EOF.
       b) Ensure a single `auth_oidc: !include auth_oidc.yaml` line is
          present at the top level. Add if missing; leave alone if not.

Why split include + main config: HA's `!env_var` swallows missing vars
and confuses the auth_oidc schema validator (reports "required key not
provided" with no useful diagnostic). Writing literal values into a
separate file dodges all of that and gives us a single source of truth
that flows through CSI rotation cleanly.

Inputs (via env on the init container):
  OIDC_DISCOVERY_URL   - full https URL to the IdP's openid-configuration

Inputs (via files on the CSI mount):
  /mnt/secrets/oidc_client_id
  /mnt/secrets/oidc_client_secret
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import sys

CONFIG = pathlib.Path("/config/configuration.yaml")
INCLUDE = pathlib.Path("/config/auth_oidc.yaml")
SECRETS = pathlib.Path("/mnt/secrets")

INCLUDE_LINE = "auth_oidc: !include auth_oidc.yaml"
# Strip a properly-formed top-level `auth_oidc:` block (auth_oidc: line
# at column 0 plus indented children). Matches non-greedy from the line
# start through everything until the next top-level YAML key or EOF.
# (?ms) → MULTILINE + DOTALL. Excludes the bare include line shape
# (auth_oidc:_!include...) — that's the line we WRITE, not strip.
INLINE_BLOCK_RE = re.compile(r"(?ms)^auth_oidc:\s*\n.*?(?=^[A-Za-z_]|\Z)")
# Strip orphan auth_oidc keys at column 0 (a previous broken append
# that lost the `auth_oidc:` parent indentation, leaving children as
# top-level YAML keys). The `!env_var OIDC_CLIENT_ID` shape is unique
# enough to anchor on without false positives. Matches from that key
# through to the next non-auth_oidc top-level key or EOF, sweeping the
# whole orphan island including the indented `automatic_user_linking`
# line under `features:`.
ORPHAN_BLOCK_RE = re.compile(
    r"(?ms)^client_id:\s*!env_var\s+OIDC_CLIENT_ID\b.*?(?=^auth_oidc:|^automation:|^script:|^scene:|^homeassistant:|^http:|^default_config|\Z)"
)


def main() -> int:
    discovery_url = os.environ.get("OIDC_DISCOVERY_URL")
    if not discovery_url:
        print("FAIL OIDC_DISCOVERY_URL env not set", file=sys.stderr)
        return 2

    try:
        client_id = (SECRETS / "oidc_client_id").read_text().strip()
        client_secret = (SECRETS / "oidc_client_secret").read_text().strip()
    except OSError as e:
        print(f"FAIL reading CSI secret: {e}", file=sys.stderr)
        return 2
    if not client_id or not client_secret:
        print("FAIL oidc_client_id or oidc_client_secret is empty", file=sys.stderr)
        return 2

    # 1) Always rewrite the include file (rotation-aware). json.dumps
    # produces JSON-style double-quoted strings — valid YAML 1.1, safely
    # escapes any special chars Zitadel might put in a client_secret.
    INCLUDE.write_text(
        f"client_id: {json.dumps(client_id)}\n"
        f"client_secret: {json.dumps(client_secret)}\n"
        f"discovery_url: {json.dumps(discovery_url)}\n"
        'display_name: "Zitadel"\n'
        "features:\n"
        "  automatic_user_linking: true\n"
    )
    print(f"OK wrote {INCLUDE}")

    # 2a) Strip any stale top-level auth_oidc block (good shape).
    text = CONFIG.read_text()
    after_inline = INLINE_BLOCK_RE.sub("", text)
    if after_inline != text:
        print("OK stripped stale inline auth_oidc block")
    # 2b) Strip orphan auth_oidc-shaped keys at column 0 (broken append
    # that lost indentation — handles the recovery case).
    after_orphan = ORPHAN_BLOCK_RE.sub("", after_inline)
    if after_orphan != after_inline:
        print("OK stripped orphan auth_oidc keys (no parent)")
    text = after_orphan.rstrip() + "\n"

    # 2c) Ensure the !include line is present.
    if INCLUDE_LINE not in text:
        text += "\n" + INCLUDE_LINE + "\n"
        print("OK appended !include line")
    else:
        print("OK !include line already present")

    CONFIG.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
