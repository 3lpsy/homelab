#!/usr/bin/env python3
"""Verify a Zitadel org domain end-to-end.

Flow:
  1. Preflight every external dep (Zitadel auth, Route53 zone, NS lookup)
  2. Idempotency: skip if domain is already verified
  3. Generate DNS challenge from Zitadel
  4. UPSERT TXT record in Route53
  5. Wait for Route53 control-plane INSYNC
  6. Poll authoritative nameservers for the actual TXT value
  7. Trigger Zitadel ValidateOrgDomain
  8. Confirm isVerified=true

Idempotent: re-runs that find the domain already verified exit 0 without
touching DNS or calling validate.

Logging discipline: every step logs STEP / OK / FAIL / WARN with structured
fields so `kubectl logs job/<name>` is enough to diagnose. Secrets are NEVER
logged: the PAT, AWS keys, and the challenge token are treated as opaque.
Only step names, status codes, record names, attempt counters, and counts
appear in log output.

Required env:
  ZITADEL_API           - https://oidc.<tailnet>
  DOMAIN                - the org domain to verify (e.g. hs.example.com)
  PAT                   - Zitadel machine-user PAT (IAM_OWNER scope)
  ROUTE53_ZONE_ID       - hosted zone id that owns DOMAIN
  AWS_ACCESS_KEY_ID     - boto3 picks this up automatically
  AWS_SECRET_ACCESS_KEY - boto3 picks this up automatically

Optional env:
  AWS_DEFAULT_REGION       (default us-east-1)
  TIMEOUT_DNS_SEC          (default 300)
  TIMEOUT_VALIDATE_SEC     (default 120)
  TIMEOUT_R53_INSYNC_SEC   (default 180)
  LOG_LEVEL                (default INFO)

Exit codes:
  0  domain verified (or was already verified)
  2  any error — see last log line for details
"""
from __future__ import annotations

import logging
import os
import sys
import time
from typing import NoReturn

import boto3
import dns.exception
import dns.resolver
import requests
from botocore.exceptions import BotoCoreError, ClientError
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


def _build_logger() -> logging.Logger:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-5s %(message)s",
    )
    return logging.getLogger("zitadel-domain-verify")


log = _build_logger()


def die(msg: str, code: int = 2) -> NoReturn:
    log.error("FAIL %s", msg)
    sys.exit(code)


def step(name: str) -> None:
    log.info("STEP %s", name)


def required_env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        die(f"missing required env var {name}")
    return v


def build_session(pat: str) -> requests.Session:
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {pat}"
    s.headers["Content-Type"] = "application/json"
    s.mount(
        "https://",
        HTTPAdapter(max_retries=Retry(
            total=5,
            backoff_factor=1.0,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=("GET", "POST"),
        )),
    )
    return s


def preflight_zitadel(session: requests.Session, api: str) -> None:
    step("preflight/zitadel-reachable")
    try:
        r = session.get(f"{api}/auth/v1/users/me", timeout=10)
    except requests.RequestException as e:
        die(f"cannot reach Zitadel API at {api}: {e}")
    if r.status_code == 401:
        die("Zitadel PAT rejected (401). Check secret/zitadel/tf-provider-pat in Vault.")
    if not r.ok:
        die(f"Zitadel auth probe failed: status={r.status_code} body[:200]={r.text[:200]!r}")
    me = r.json().get("user", {})
    log.info("OK   preflight/zitadel-reachable user=%s",
             me.get("preferredLoginName", "<unknown>"))


def preflight_route53(zone_id: str, domain: str) -> tuple[boto3.client, str]:
    step("preflight/route53-zone-accessible")
    try:
        r53 = boto3.client("route53")
        zone = r53.get_hosted_zone(Id=zone_id)
    except (BotoCoreError, ClientError) as e:
        die(f"cannot access Route53 zone {zone_id}: {e}")
    zone_name = zone["HostedZone"]["Name"].rstrip(".")
    if not (domain == zone_name or domain.endswith("." + zone_name)):
        die(f"domain {domain} is not under hosted zone {zone_name}")
    log.info("OK   preflight/route53-zone-accessible zone=%s", zone_name)
    return r53, zone_name


def discover_authoritative_ns(zone_name: str) -> list[str]:
    step("preflight/discover-authoritative-ns")
    try:
        ns_records = [r.to_text() for r in dns.resolver.resolve(zone_name, "NS")]
    except dns.exception.DNSException as e:
        die(f"NS lookup for zone {zone_name} failed: {e}")
    auth_ns_ips: list[str] = []
    for ns in ns_records:
        try:
            for a in dns.resolver.resolve(ns, "A"):
                auth_ns_ips.append(a.to_text())
        except dns.exception.DNSException as e:
            log.warning("WARN preflight/discover-authoritative-ns nameserver=%s lookup_failed=%s", ns, e)
    if not auth_ns_ips:
        die(f"no authoritative NS A-records resolved for {zone_name}")
    log.info("OK   preflight/discover-authoritative-ns count=%d", len(auth_ns_ips))
    return auth_ns_ips


def search_domain(session: requests.Session, api: str, domain: str) -> dict | None:
    r = session.post(
        f"{api}/management/v1/orgs/me/domains/_search",
        json={"queries": [{
            "domainNameQuery": {"name": domain, "method": "TEXT_QUERY_METHOD_EQUALS"}
        }]},
        timeout=10,
    )
    if not r.ok:
        die(f"domain search failed: status={r.status_code} body[:200]={r.text[:200]!r}")
    result = r.json().get("result", [])
    return result[0] if result else None


def fetch_domain_state(session: requests.Session, api: str, domain: str) -> dict:
    step("idempotency/check-current-status")
    record = search_domain(session, api, domain)
    if record is None:
        die(f"domain {domain} not found on org. Apply the zitadel_domain TF resource first.")
    verified = bool(record.get("isVerified"))
    primary = bool(record.get("isPrimary"))
    log.info("OK   idempotency/check-current-status verified=%s primary=%s",
             verified, primary)
    return {"isVerified": verified, "isPrimary": primary}


def generate_challenge(session: requests.Session, api: str, domain: str) -> str:
    step("generate-challenge")
    # Zitadel grpc-gateway uses leading-underscore action verbs:
    # `_generate`, `_validate`, `_search`. Without the underscore the
    # gateway returns 404 (wrong route) — easy to miss because search
    # already had the underscore so /domains/_search worked.
    r = session.post(
        f"{api}/management/v1/orgs/me/domains/{domain}/validation/_generate",
        json={"type": "DOMAIN_VALIDATION_TYPE_DNS"},
        timeout=10,
    )
    if not r.ok:
        die(f"generate challenge failed: status={r.status_code} body[:300]={r.text[:300]!r}")
    token = r.json().get("token")
    if not token:
        die("generate challenge response missing 'token' field")
    # Token is treated as a secret — log only its presence and length.
    log.info("OK   generate-challenge token_present=true token_len=%d", len(token))
    return token


def upsert_txt(r53: boto3.client, zone_id: str, name: str, value: str) -> str:
    step(f"route53-upsert record={name}")
    try:
        change = r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={
                "Comment": "zitadel domain verification",
                "Changes": [{
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": name,
                        "Type": "TXT",
                        "TTL": 60,
                        "ResourceRecords": [{"Value": f'"{value}"'}],
                    },
                }],
            },
        )
    except (BotoCoreError, ClientError) as e:
        die(f"Route53 UPSERT failed: {e}")
    change_id = change["ChangeInfo"]["Id"]
    log.info("OK   route53-upsert change_id=%s", change_id)
    return change_id


def wait_route53_insync(r53: boto3.client, change_id: str, timeout_sec: int) -> None:
    step(f"route53-wait-insync timeout={timeout_sec}s")
    deadline = time.time() + timeout_sec
    elapsed = 0.0
    while time.time() < deadline:
        try:
            status = r53.get_change(Id=change_id)["ChangeInfo"]["Status"]
        except (BotoCoreError, ClientError) as e:
            log.warning("WARN route53-wait-insync get_change_error=%s", e)
            status = "ERROR"
        if status == "INSYNC":
            log.info("OK   route53-wait-insync elapsed=%.0fs", elapsed)
            return
        time.sleep(5)
        elapsed += 5
    die(f"Route53 change {change_id} did not reach INSYNC in {timeout_sec}s")


def poll_authoritative_dns(
    record_name: str,
    expected_token: str,
    auth_ns_ips: list[str],
    timeout_sec: int,
) -> None:
    step(f"dns-poll-authoritative timeout={timeout_sec}s ns_count={len(auth_ns_ips)}")
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = auth_ns_ips
    resolver.lifetime = 5
    deadline = time.time() + timeout_sec
    elapsed = 0.0
    last_err: str | None = None
    while time.time() < deadline:
        try:
            ans = resolver.resolve(record_name.rstrip("."), "TXT")
            # Token never appears in logs — match by membership only.
            if any(expected_token in rr.to_text() for rr in ans):
                log.info("OK   dns-poll-authoritative elapsed=%.0fs", elapsed)
                return
            log.debug("dns-poll-authoritative txt_present_but_token_missing")
        except dns.exception.DNSException as e:
            last_err = str(e)
            log.debug("dns-poll-authoritative not_yet=%s", e)
        time.sleep(5)
        elapsed += 5
    die(
        f"TXT record did not propagate to authoritative NS in {timeout_sec}s "
        f"(last_err={last_err})"
    )


def trigger_validate(
    session: requests.Session, api: str, domain: str, timeout_sec: int
) -> None:
    step(f"zitadel-validate timeout={timeout_sec}s")
    deadline = time.time() + timeout_sec
    last_err: str | None = None
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        # Both generate and validate sit under /validation/_<verb>. Easy to
        # get wrong — early version had /_validate (no `validation/`) and
        # 404'd here while generate at /validation/_generate worked fine.
        r = session.post(
            f"{api}/management/v1/orgs/me/domains/{domain}/validation/_validate",
            json={},
            timeout=15,
        )
        if r.ok:
            log.info("OK   zitadel-validate attempt=%d status=%d", attempt, r.status_code)
            return
        last_err = f"status={r.status_code} body[:200]={r.text[:200]!r}"
        log.warning("WARN zitadel-validate attempt=%d %s", attempt, last_err)
        time.sleep(5)
    die(f"ValidateOrgDomain did not succeed in {timeout_sec}s (last={last_err})")


def _await_flag(session: requests.Session, api: str, domain: str,
                flag: str, *, timeout_sec: int) -> None:
    """Poll the search projection until `flag` (e.g. isVerified) flips true.

    Zitadel is event-sourced: commands return 200 the moment the event is
    persisted, but the read-side projection (which `_search` queries) lags
    by ~ms-to-seconds. A single search right after the command often shows
    the pre-command state. Poll with a short cap.
    """
    deadline = time.time() + timeout_sec
    last_state: dict | None = None
    while time.time() < deadline:
        record = search_domain(session, api, domain)
        if record and record.get(flag):
            log.info("OK   confirm/%s domain=%s", flag, domain)
            return
        last_state = record
        time.sleep(1)
    die(f"command returned ok but {flag} did not flip true within {timeout_sec}s "
        f"(last_state={last_state!r})")


def confirm_verified(session: requests.Session, api: str, domain: str) -> None:
    step("confirm-verified")
    _await_flag(session, api, domain, "isVerified", timeout_sec=30)


def set_primary(session: requests.Session, api: str, domain: str) -> None:
    """Promote the (verified) domain to primary on the org.

    Idempotent — caller checks isPrimary first and skips if already true.
    Path is /orgs/me/domains/{domain}/_set_primary (no `validation/` prefix
    here, unlike _generate and _validate). Body is an empty object.
    """
    step("zitadel-set-primary")
    r = session.post(
        f"{api}/management/v1/orgs/me/domains/{domain}/_set_primary",
        json={},
        timeout=15,
    )
    if not r.ok:
        die(f"SetPrimaryOrgDomain failed: status={r.status_code} body[:200]={r.text[:200]!r}")
    log.info("OK   zitadel-set-primary status=%d", r.status_code)


def confirm_primary(session: requests.Session, api: str, domain: str) -> None:
    step("confirm-primary")
    _await_flag(session, api, domain, "isPrimary", timeout_sec=30)


def main() -> int:
    api = required_env("ZITADEL_API").rstrip("/")
    domain = required_env("DOMAIN")
    pat = required_env("PAT")
    zone_id = required_env("ROUTE53_ZONE_ID")
    timeout_dns = int(os.environ.get("TIMEOUT_DNS_SEC", "300"))
    timeout_validate = int(os.environ.get("TIMEOUT_VALIDATE_SEC", "120"))
    timeout_insync = int(os.environ.get("TIMEOUT_R53_INSYNC_SEC", "180"))

    log.info(
        "config api=%s domain=%s zone=%s timeouts(dns=%ds,r53=%ds,validate=%ds)",
        api, domain, zone_id, timeout_dns, timeout_insync, timeout_validate,
    )

    session = build_session(pat)

    preflight_zitadel(session, api)
    r53, zone_name = preflight_route53(zone_id, domain)
    auth_ns_ips = discover_authoritative_ns(zone_name)

    state = fetch_domain_state(session, api, domain)

    # Verification path — only run if not already verified.
    if not state["isVerified"]:
        token = generate_challenge(session, api, domain)
        record_name = f"_zitadel-challenge.{domain}."
        change_id = upsert_txt(r53, zone_id, record_name, token)
        wait_route53_insync(r53, change_id, timeout_insync)
        poll_authoritative_dns(record_name, token, auth_ns_ips, timeout_dns)
        trigger_validate(session, api, domain, timeout_validate)
        confirm_verified(session, api, domain)

    # Primary-flip path — only run if not already primary.
    if not state["isPrimary"]:
        set_primary(session, api, domain)
        confirm_primary(session, api, domain)

    log.info("DONE domain=%s verified=true primary=true", domain)
    return 0


if __name__ == "__main__":
    sys.exit(main())
