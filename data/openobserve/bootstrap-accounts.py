#!/usr/bin/env python3
"""Bootstrap OpenObserve service accounts (ingester, provisioner).

Idempotent. Runs at deploy time. Flow:
  1. Login to Vault using this pod's Kubernetes SA token -> Vault client token.
  2. Read root creds from Vault KV.
  3. Wait for OpenObserve /healthz.
  4. For each target service account:
       - GET existing; skip if present AND Vault KV already holds a basic_b64.
       - Otherwise POST to /service_accounts, capture the generated password from
         the response, compute basic_b64 = b64(email:password), write to Vault.
  5. Exit 0 on full success.

Env:
  VAULT_ADDR           e.g. http://vault.vault.svc.cluster.local:8200
  VAULT_ROLE           Vault K8s auth role name (openobserve-bootstrap)
  VAULT_MOUNT          KV v2 mount path (from vault-conf outputs)
  OO_URL               http://openobserve.monitoring.svc.cluster.local:5080
  OO_ORG               default
  ROOT_EMAIL           ZO_ROOT_USER_EMAIL (mounted from Vault via CSI)
  ROOT_BASIC_B64       root basic_b64 (mounted from Vault via CSI)
  ACCOUNTS_JSON        JSON list: [{"name":"ingester","email":"...","first_name":"...","last_name":"..."}, ...]
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

VAULT_ADDR = os.environ["VAULT_ADDR"].rstrip("/")
VAULT_ROLE = os.environ["VAULT_ROLE"]
VAULT_MOUNT = os.environ["VAULT_MOUNT"].strip("/")
OO_URL = os.environ["OO_URL"].rstrip("/")
OO_ORG = os.environ["OO_ORG"]
ROOT_BASIC_B64 = os.environ["ROOT_BASIC_B64"]
ACCOUNTS = json.loads(os.environ["ACCOUNTS_JSON"])

SA_TOKEN_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")


def http(method: str, url: str, headers: dict, body: dict | None = None, timeout: int = 30) -> tuple[int, dict | list | None, bytes]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            parsed = json.loads(raw) if raw else None
            return resp.status, parsed, raw
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw) if raw else None
        except Exception:
            parsed = None
        return e.code, parsed, raw


def vault_login() -> str:
    jwt = SA_TOKEN_PATH.read_text()
    status, body, raw = http(
        "POST", f"{VAULT_ADDR}/v1/auth/kubernetes/login",
        headers={"Content-Type": "application/json"},
        body={"role": VAULT_ROLE, "jwt": jwt},
    )
    if status != 200 or not body:
        raise RuntimeError(f"vault login failed {status}: {raw!r}")
    return body["auth"]["client_token"]


def vault_read(vault_token: str, path: str) -> dict | None:
    status, body, raw = http(
        "GET", f"{VAULT_ADDR}/v1/{VAULT_MOUNT}/data/{path}",
        headers={"X-Vault-Token": vault_token},
    )
    if status == 404:
        return None
    if status != 200 or not body:
        raise RuntimeError(f"vault read {path} failed {status}: {raw!r}")
    return body["data"]["data"]


def vault_write(vault_token: str, path: str, data: dict) -> None:
    status, _, raw = http(
        "POST", f"{VAULT_ADDR}/v1/{VAULT_MOUNT}/data/{path}",
        headers={"X-Vault-Token": vault_token, "Content-Type": "application/json"},
        body={"data": data},
    )
    if status not in (200, 204):
        raise RuntimeError(f"vault write {path} failed {status}: {raw!r}")


def oo_request(method: str, path: str, body: dict | None = None) -> tuple[int, dict | list | None, bytes]:
    return http(
        method, f"{OO_URL}{path}",
        headers={
            "Authorization": f"Basic {ROOT_BASIC_B64}",
            "Content-Type": "application/json",
        },
        body=body,
    )


def wait_oo_ready(max_wait: int = 180) -> None:
    deadline = time.time() + max_wait
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{OO_URL}/healthz", timeout=5) as r:
                if r.status == 200:
                    print(f"openobserve ready at {OO_URL}")
                    return
        except Exception as e:
            print(f"waiting for openobserve: {e}")
        time.sleep(3)
    raise RuntimeError(f"timed out waiting for {OO_URL}/healthz")


def list_service_accounts() -> list[dict]:
    status, body, raw = oo_request("GET", f"/api/{OO_ORG}/service_accounts")
    if status != 200:
        raise RuntimeError(f"list service_accounts failed {status}: {raw!r}")
    if isinstance(body, dict):
        return body.get("data") or body.get("list") or body.get("users") or []
    if isinstance(body, list):
        return body
    return []


def create_service_account(email: str, first_name: str, last_name: str) -> str:
    """Create a service account and return its generated password."""
    status, body, raw = oo_request(
        "POST", f"/api/{OO_ORG}/service_accounts",
        body={"email": email, "first_name": first_name, "last_name": last_name},
    )
    if status not in (200, 201):
        raise RuntimeError(f"create service_account {email} failed {status}: {raw!r}")
    if not isinstance(body, dict):
        raise RuntimeError(f"unexpected create response: {raw!r}")
    # OO response shape varies by version. Try known fields.
    for key in ("password", "token", "passcode"):
        if key in body and body[key]:
            return body[key]
        data = body.get("data") if isinstance(body.get("data"), dict) else None
        if data and key in data and data[key]:
            return data[key]
    raise RuntimeError(f"could not find generated password in response: {raw!r}")


def rotate_passcode(email: str) -> str:
    """Fallback: rotate an existing service account's passcode."""
    status, body, raw = oo_request(
        "PUT", f"/api/{OO_ORG}/service_accounts/{email}?rotateToken=true",
    )
    if status not in (200, 201):
        raise RuntimeError(f"rotate passcode {email} failed {status}: {raw!r}")
    if isinstance(body, dict):
        for key in ("password", "token", "passcode"):
            if key in body and body[key]:
                return body[key]
            data = body.get("data") if isinstance(body.get("data"), dict) else None
            if data and key in data and data[key]:
                return data[key]
    raise RuntimeError(f"could not find rotated passcode in response: {raw!r}")


def main() -> int:
    print("vault login")
    vault_token = vault_login()

    wait_oo_ready()

    print("listing existing service accounts")
    existing = list_service_accounts()
    existing_emails = {(sa.get("email") or "").lower() for sa in existing}

    for acct in ACCOUNTS:
        name = acct["name"]
        email = acct["email"]
        vault_path = f"openobserve/service-accounts/{name}"
        print(f"--- {name} ({email}) ---")

        vault_data = vault_read(vault_token, vault_path)
        has_vault_creds = bool(vault_data and vault_data.get("basic_b64"))

        if email.lower() in existing_emails and has_vault_creds:
            print(f"{name}: already provisioned, skipping")
            continue

        if email.lower() in existing_emails and not has_vault_creds:
            # Account exists in OO but Vault lost its creds. Rotate and store.
            print(f"{name}: exists in OO but no creds in Vault -> rotating passcode")
            password = rotate_passcode(email)
        else:
            print(f"{name}: creating service account")
            password = create_service_account(email, acct["first_name"], acct["last_name"])

        basic_b64 = base64.b64encode(f"{email}:{password}".encode()).decode()
        vault_write(vault_token, vault_path, {
            "email": email,
            "password": password,
            "basic_b64": basic_b64,
        })
        print(f"{name}: wrote creds to vault at {VAULT_MOUNT}/{vault_path}")

    print("bootstrap complete")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"FATAL: {e}", file=sys.stderr)
        sys.exit(1)
