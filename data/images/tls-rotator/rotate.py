#!/usr/bin/env python3
"""TLS rotation worker.

Reads a list of certs from a ConfigMap, renews any within RENEW_THRESHOLD_DAYS
of expiry via lego (DNS-01 against Route53 using temporary STS creds), writes
the resulting fullchain + private key back to Vault. Reloader handles pod
restarts by watching the synced K8s secrets.

Idempotent: re-runs that find every cert still fresh exit 0 with no work.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import boto3
from cryptography import x509

VAULT_ADDR = os.environ["VAULT_ADDR"].rstrip("/")
VAULT_ROLE = os.environ["VAULT_ROLE"]
VAULT_MOUNT = os.environ["VAULT_MOUNT"].strip("/")
ACME_SERVER = os.environ.get("ACME_SERVER", "https://acme-v02.api.letsencrypt.org/directory")
RENEW_THRESHOLD_DAYS = int(os.environ.get("RENEW_THRESHOLD_DAYS", "30"))
CERTS_FILE = Path(os.environ.get("CERTS_FILE", "/etc/tls-rotator/certs.json"))
WORK_DIR = Path(os.environ.get("WORK_DIR", "/work"))
RECURSIVE_NS = os.environ.get("RECURSIVE_NAMESERVERS", "9.9.9.9:53,149.112.112.112:53")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

SA_TOKEN_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
# Quiet boto3/urllib3 chatter; keep our own logs at the configured level.
logging.getLogger("botocore").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)
log = logging.getLogger("tls-rotator")


def http(method: str, url: str, headers: dict, body: dict | None = None, timeout: int = 30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None), raw
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw) if raw else None
        except Exception:
            parsed = None
        return e.code, parsed, raw


def vault_login() -> str:
    jwt = SA_TOKEN_PATH.read_text()
    s, b, raw = http(
        "POST", f"{VAULT_ADDR}/v1/auth/kubernetes/login",
        {"Content-Type": "application/json"},
        {"role": VAULT_ROLE, "jwt": jwt},
    )
    if s != 200 or not b:
        raise RuntimeError(f"vault login failed {s}: {raw!r}")
    return b["auth"]["client_token"]


def vault_read(token: str, path: str) -> dict | None:
    s, b, raw = http(
        "GET", f"{VAULT_ADDR}/v1/{VAULT_MOUNT}/data/{path}",
        {"X-Vault-Token": token},
    )
    if s == 404:
        return None
    if s != 200 or not b:
        raise RuntimeError(f"vault read {path} failed {s}: {raw!r}")
    return b["data"]["data"]


def vault_write(token: str, path: str, data: dict) -> None:
    s, _, raw = http(
        "POST", f"{VAULT_ADDR}/v1/{VAULT_MOUNT}/data/{path}",
        {"X-Vault-Token": token, "Content-Type": "application/json"},
        {"data": data},
    )
    if s not in (200, 204):
        raise RuntimeError(f"vault write {path} failed {s}: {raw!r}")


def _parse_pem(pem: str):
    try:
        return x509.load_pem_x509_certificate(pem.encode())
    except Exception:
        return None


def _not_before(cert) -> datetime:
    return (
        cert.not_valid_before_utc
        if hasattr(cert, "not_valid_before_utc")
        else cert.not_valid_before.replace(tzinfo=timezone.utc)
    )


def _not_after(cert) -> datetime:
    return (
        cert.not_valid_after_utc
        if hasattr(cert, "not_valid_after_utc")
        else cert.not_valid_after.replace(tzinfo=timezone.utc)
    )


def days_until_expiry(pem: str) -> float | None:
    cert = _parse_pem(pem)
    if cert is None:
        return None
    return (_not_after(cert) - datetime.now(timezone.utc)).total_seconds() / 86400


def cert_info(pem: str) -> dict | None:
    """Public-only summary of a PEM cert. Logged at INFO before/after rotation
    so each run has an audit trail of what was on disk and what replaced it."""
    cert = _parse_pem(pem)
    if cert is None:
        return None
    return {
        "subject": cert.subject.rfc4514_string(),
        "issuer": cert.issuer.rfc4514_string(),
        "issued_at": _not_before(cert).isoformat(),
        "expires_at": _not_after(cert).isoformat(),
        "serial": format(cert.serial_number, "x"),
    }


def _log_cert(prefix: str, name: str, info: dict | None) -> None:
    if info is None:
        log.info("%s %s: <no cert>", prefix, name)
        return
    log.info(
        "%s %s: subject=%s issuer=%s issued=%s expires=%s serial=%s",
        prefix, name, info["subject"], info["issuer"],
        info["issued_at"], info["expires_at"], info["serial"],
    )


def assume_role(aws_creds: dict) -> dict:
    sts = boto3.client(
        "sts",
        aws_access_key_id=aws_creds["aws_access_key_id"],
        aws_secret_access_key=aws_creds["aws_secret_access_key"],
        region_name=aws_creds["aws_region"],
    )
    resp = sts.assume_role(
        RoleArn=aws_creds["role_arn"],
        RoleSessionName=f"tls-rotator-{int(time.time())}",
    )
    c = resp["Credentials"]
    return {
        "AccessKeyId": c["AccessKeyId"],
        "SecretAccessKey": c["SecretAccessKey"],
        "SessionToken": c["SessionToken"],
        "Region": aws_creds["aws_region"],
    }


def write_account_key(email: str, account_key_pem: str) -> None:
    # lego stores account keys at <path>/accounts/<server-host>/<email>/keys/<email>.key
    server_host = ACME_SERVER.split("//", 1)[-1].split("/", 1)[0]
    keys_dir = WORK_DIR / "accounts" / server_host / email / "keys"
    keys_dir.mkdir(parents=True, exist_ok=True)
    (keys_dir / f"{email}.key").write_text(account_key_pem)


def lego_base_args(email: str, sts_creds: dict) -> tuple[list[str], dict]:
    args = [
        "lego",
        "--accept-tos",
        "--email", email,
        "--server", ACME_SERVER,
        "--path", str(WORK_DIR),
        "--dns", "route53",
        "--dns.resolvers", RECURSIVE_NS,
    ]
    env = {
        **os.environ,
        "AWS_ACCESS_KEY_ID": sts_creds["AccessKeyId"],
        "AWS_SECRET_ACCESS_KEY": sts_creds["SecretAccessKey"],
        "AWS_SESSION_TOKEN": sts_creds["SessionToken"],
        "AWS_REGION": sts_creds["Region"],
        "AWS_DEFAULT_REGION": sts_creds["Region"],
    }
    return args, env


def lego_issue(domain: str, email: str, sts_creds: dict) -> tuple[str, str]:
    """Issue (or re-issue) a cert via `lego run`.

    Always `run`, never `renew`: lego's `renew` requires account.json on
    disk, which we don't have because each CronJob pod gets a fresh
    emptyDir for WORK_DIR. `run` registers the account first (idempotent —
    Let's Encrypt returns the existing account when the key matches) and
    then issues. We've already gated on days-remaining in process_cert, so
    `run` only fires when we actually want a new cert."""
    args, env = lego_base_args(email, sts_creds)
    args += ["--domains", domain, "run"]
    log.info("lego run %s", domain)
    r = subprocess.run(args, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"lego failed for {domain}: {r.stdout}\n{r.stderr}")
    crt = (WORK_DIR / "certificates" / f"{domain}.crt").read_text()
    key = (WORK_DIR / "certificates" / f"{domain}.key").read_text()
    return crt, key


def process_cert(token: str, sts_creds: dict, email: str, entry: dict) -> str:
    name = entry["name"]
    domain = entry["domain"]
    vault_path = entry["vault_path"]

    current = vault_read(token, vault_path) or {}
    fullchain = current.get("fullchain_pem", "")
    privkey = current.get("privkey_pem", "")

    _log_cert("current", name, cert_info(fullchain) if fullchain else None)

    days = days_until_expiry(fullchain) if fullchain else None
    if days is not None and days > RENEW_THRESHOLD_DAYS:
        log.info("%s (%s): %.1fd remaining > %dd, skip", name, domain, days, RENEW_THRESHOLD_DAYS)
        return "skipped"

    new_fullchain, new_privkey = lego_issue(domain, email, sts_creds)

    vault_write(token, vault_path, {
        "fullchain_pem": new_fullchain,
        "privkey_pem": new_privkey,
    })
    _log_cert("new    ", name, cert_info(new_fullchain))
    new_days = days_until_expiry(new_fullchain)
    log.info(
        "%s (%s): rotated, %.1fd remaining, wrote %s/%s",
        name, domain, new_days if new_days is not None else -1.0, VAULT_MOUNT, vault_path,
    )
    return "rotated"


def main() -> int:
    log.info("vault login")
    token = vault_login()

    aws = vault_read(token, "tls-rotator/aws")
    if not aws:
        raise RuntimeError("missing tls-rotator/aws in vault")
    acct = vault_read(token, "tls-rotator/acme-account")
    if not acct:
        raise RuntimeError("missing tls-rotator/acme-account in vault")
    email = acct["email"]

    log.info("assume role %s", aws["role_arn"])
    sts_creds = assume_role(aws)

    # lego has no `register` subcommand — it self-recovers the existing
    # ACME registration from the on-disk account key (POSTs new-acct with
    # onlyReturnExisting=true) on the first run/renew call.
    write_account_key(email, acct["account_key_pem"])

    certs = json.loads(CERTS_FILE.read_text())
    log.info("processing %d certs", len(certs))

    # Continue past per-cert failures so a single broken zone or DNS-01
    # propagation flake doesn't block the other 15 from rotating. Log each
    # failure at CRITICAL (with traceback) and exit non-zero at the end so
    # the Job is marked Failed and the Prometheus alert fires.
    failures = []
    summary = {"rotated": 0, "skipped": 0, "failed": 0}
    for entry in certs:
        try:
            outcome = process_cert(token, sts_creds, email, entry)
            summary[outcome] += 1
        except Exception:
            name = entry.get("name", "<unknown>")
            log.critical("FAILED to rotate %s", name, exc_info=True)
            failures.append(name)
            summary["failed"] += 1

    log.info("summary: %s", summary)
    if failures:
        log.critical("rotation failed for %d cert(s): %s", len(failures), failures)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        log.critical("FATAL", exc_info=True)
        sys.exit(1)
