#!/usr/bin/env python3
"""Terraform `data.external` helper: read the K3s server node-token over SSH.

artemis joins delphi's control plane as a K3s *agent*, which needs delphi's
server node-token (`/var/lib/rancher/k3s/server/node-token`). Rather than
parking the token in a tfvar or routing it through Vault (cluster/ is
deployment #2, Vault is #3 — wiring a Vault provider here would invert the
deployment order), we read it at apply time over the same SSH access the TF
host already uses for every cluster provisioner.

`data.external` protocol: the `query` object arrives as a JSON object on
stdin; we must print a flat {string: string} JSON object on stdout. We emit
`{"token": "<server node-token>"}`.

The token only rotates if K3s is reinstalled on the server, so an apply-time
read is stable.

Wired from cluster.tf as:

    data "external" "k3s_node_token" {
      program    = ["python3", "${path.module}/../data/scripts/read-k3s-token.py"]
      query      = { host = "<delphi-fqdn>", ssh_user = "...", ssh_key_path = "..." }
      depends_on = [module.cluster-provision]   # delphi's k3s up first
    }
"""
from __future__ import annotations

import json
import subprocess
import sys

TOKEN_PATH = "/var/lib/rancher/k3s/server/node-token"


def read_token(host, ssh_user, ssh_key_path, runner=subprocess.run):
    """SSH `host` and return the stripped K3s server node-token.

    `runner` is injectable so the SSH boundary can be faked in tests.
    """
    cmd = [
        "ssh",
        "-i", ssh_key_path,
        # Use only the provided key (match Terraform's provisioner semantics);
        # BatchMode so a passphrase/host-key prompt fails fast instead of
        # hanging the apply. The provisioner key must be passphraseless — the
        # same key TF's remote-exec provisioners already use non-interactively.
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        f"{ssh_user}@{host}",
        f"sudo cat {TOKEN_PATH}",
    ]
    result = runner(cmd, capture_output=True, text=True, check=True)
    token = result.stdout.strip()
    if not token:
        raise ValueError(f"empty K3s node-token read from {host}:{TOKEN_PATH}")
    return token


def main(stdin=None, stdout=None):
    stdin = stdin if stdin is not None else sys.stdin
    stdout = stdout if stdout is not None else sys.stdout

    query = json.load(stdin)
    for key in ("host", "ssh_user", "ssh_key_path"):
        if not query.get(key):
            raise KeyError(f"missing required query field: {key}")

    token = read_token(query["host"], query["ssh_user"], query["ssh_key_path"])
    json.dump({"token": token}, stdout)


if __name__ == "__main__":
    main()
