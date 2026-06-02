"""Tests for zitadel-domain-verify.py.

Covers the critical contracts:
  - idempotent skip when domain already verified
  - preflight failures abort before mutating any state
  - happy path executes every step in order
  - DNS propagation timeout fails fast with a useful message
  - validate retries on transient 5xx
  - secrets (PAT, token) never appear in log output

Run with:

  uv run --with pytest --with requests --with boto3 --with dnspython \\
    pytest data/scripts/test_zitadel_domain_verify.py
"""
from __future__ import annotations

import importlib.util
import logging
import os
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest


# Load the script as a module — name has a hyphen so a regular import fails.
def _load_module() -> Any:
    here = Path(__file__).parent
    spec = importlib.util.spec_from_file_location(
        "zitadel_domain_verify", here / "zitadel-domain-verify.py"
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


vd = _load_module()


# --- env fixture ------------------------------------------------------------

PAT_VALUE = "pat-abc-do-not-log"
TOKEN_VALUE = "tok-xyz-do-not-log"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> None:
    for k, v in {
        "ZITADEL_API": "https://oidc.example",
        "DOMAIN": "hs.example.com",
        "PAT": PAT_VALUE,
        "ROUTE53_ZONE_ID": "ZTESTID",
        "AWS_DEFAULT_REGION": "us-east-1",
        "TIMEOUT_DNS_SEC": "2",
        "TIMEOUT_VALIDATE_SEC": "2",
        "TIMEOUT_R53_INSYNC_SEC": "2",
    }.items():
        monkeypatch.setenv(k, v)


# --- HTTP fakes -------------------------------------------------------------

class FakeResponse:
    def __init__(self, status_code: int = 200, json_body: dict | None = None,
                 text: str = ""):
        self.status_code = status_code
        self._json = json_body or {}
        self.text = text or (str(json_body) if json_body else "")

    @property
    def ok(self) -> bool:
        return 200 <= self.status_code < 300

    def json(self) -> dict:
        return self._json

    def raise_for_status(self) -> None:
        if not self.ok:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeSession:
    """Minimal stand-in for requests.Session used by the script."""

    def __init__(self) -> None:
        self.headers: dict = {}
        self.get_calls: list[tuple[str, dict]] = []
        self.post_calls: list[tuple[str, dict]] = []
        # url-suffix → list of FakeResponse to return in order
        self.get_responses: dict[str, list[FakeResponse]] = {}
        self.post_responses: dict[str, list[FakeResponse]] = {}

    def mount(self, *_: Any, **__: Any) -> None:
        pass

    def _next(self, table: dict[str, list[FakeResponse]], url: str) -> FakeResponse:
        for suffix, responses in table.items():
            if url.endswith(suffix):
                if not responses:
                    raise RuntimeError(f"no canned responses left for {suffix}")
                return responses.pop(0) if len(responses) > 1 else responses[0]
        raise RuntimeError(f"unmocked URL: {url}")

    def get(self, url: str, **kwargs: Any) -> FakeResponse:
        self.get_calls.append((url, kwargs))
        return self._next(self.get_responses, url)

    def post(self, url: str, **kwargs: Any) -> FakeResponse:
        self.post_calls.append((url, kwargs))
        return self._next(self.post_responses, url)


# --- Route53 fakes ----------------------------------------------------------

def make_r53(insync_after: int = 1, raise_on_change: bool = False) -> MagicMock:
    """Return a Mock that mimics the boto3 route53 client subset we use."""
    r53 = MagicMock()
    r53.get_hosted_zone.return_value = {"HostedZone": {"Name": "hs.example.com."}}
    if raise_on_change:
        from botocore.exceptions import ClientError
        r53.change_resource_record_sets.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "denied"}},
            "ChangeResourceRecordSets",
        )
    else:
        r53.change_resource_record_sets.return_value = {
            "ChangeInfo": {"Id": "/change/CHG123", "Status": "PENDING"}
        }
    counter = {"n": 0}

    def get_change(**_: Any) -> dict:
        counter["n"] += 1
        status = "INSYNC" if counter["n"] >= insync_after else "PENDING"
        return {"ChangeInfo": {"Id": "/change/CHG123", "Status": status}}

    r53.get_change.side_effect = get_change
    return r53


# --- DNS fakes --------------------------------------------------------------

class FakeRRset:
    def __init__(self, text: str):
        self._text = text

    def to_text(self) -> str:
        return self._text


class FakeAnswer:
    def __init__(self, items: list[FakeRRset]):
        self._items = items

    def __iter__(self):
        return iter(self._items)


def patch_dns(monkeypatch: pytest.MonkeyPatch, *,
              ns_records: list[str] | None = None,
              ns_a_records: dict[str, list[str]] | None = None,
              authoritative_txt: list[str] | None = None) -> None:
    """Wire dns.resolver.resolve + Resolver to return canned data.

    ns_records: TXT-shaped strings returned for NS lookup of the zone.
    ns_a_records: per-NS A-record IPs.
    authoritative_txt: TXT-shaped strings returned by the authoritative
        Resolver for _zitadel-challenge.<DOMAIN>. None → resolver raises.
    """
    ns_records = ns_records or ["ns-1.aws.test.", "ns-2.aws.test."]
    ns_a_records = ns_a_records or {
        "ns-1.aws.test.": ["10.0.0.1"], "ns-2.aws.test.": ["10.0.0.2"]
    }

    def fake_resolve(name: str, rdtype: str, *_: Any, **__: Any) -> FakeAnswer:
        if rdtype == "NS":
            return FakeAnswer([FakeRRset(t) for t in ns_records])
        if rdtype == "A":
            ips = ns_a_records.get(str(name), ns_a_records.get(str(name) + ".", []))
            return FakeAnswer([FakeRRset(ip) for ip in ips])
        raise vd.dns.exception.DNSException(f"unmocked rdtype {rdtype}")

    monkeypatch.setattr(vd.dns.resolver, "resolve", fake_resolve)

    class FakeResolver:
        def __init__(self, *_: Any, **__: Any) -> None:
            self.nameservers: list[str] = []
            self.lifetime: float = 5.0

        def resolve(self, _name: str, rdtype: str) -> FakeAnswer:
            if authoritative_txt is None:
                raise vd.dns.exception.DNSException("NXDOMAIN-fake")
            return FakeAnswer([FakeRRset(t) for t in authoritative_txt])

    monkeypatch.setattr(vd.dns.resolver, "Resolver", FakeResolver)


# --- helpers ----------------------------------------------------------------

ZITADEL_API = "https://oidc.example"
DOMAIN = "hs.example.com"

USERS_ME_OK = FakeResponse(200, {"user": {"preferredLoginName": "tf-provider@homelab"}})
SEARCH_VERIFIED_PRIMARY = FakeResponse(200, {"result": [{"isVerified": True, "isPrimary": True}]})
SEARCH_VERIFIED_NOT_PRIMARY = FakeResponse(200, {"result": [{"isVerified": True, "isPrimary": False}]})
SEARCH_NOT_VERIFIED = FakeResponse(200, {"result": [{"isVerified": False, "isPrimary": False}]})
SEARCH_MISSING = FakeResponse(200, {"result": []})
GENERATE_OK = FakeResponse(200, {"token": TOKEN_VALUE})
VALIDATE_OK = FakeResponse(200, {})
SET_PRIMARY_OK = FakeResponse(200, {})


def make_happy_session(*, validate_5xx_first: bool = False) -> FakeSession:
    """Sequence of search responses across the run:
       1) initial fetch_domain_state    → not verified, not primary
       2) confirm_verified              → verified=true, not primary yet
       3) confirm_primary               → verified=true, primary=true
    """
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    validate_responses = (
        [FakeResponse(503, {}, text="upstream busy"), VALIDATE_OK]
        if validate_5xx_first else [VALIDATE_OK]
    )
    s.post_responses = {
        "/domains/_search": [
            SEARCH_NOT_VERIFIED,
            SEARCH_VERIFIED_NOT_PRIMARY,
            SEARCH_VERIFIED_PRIMARY,
        ],
        "/validation/_generate": [GENERATE_OK],
        "/validation/_validate": validate_responses,
        "/_set_primary":         [SET_PRIMARY_OK],
    }
    return s


# ============================================================================
# Tests
# ============================================================================

def test_idempotent_skip_when_already_verified_and_primary(monkeypatch, caplog) -> None:
    """Already verified+primary → exit 0 without touching Route53 or APIs."""
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    s.post_responses = {"/domains/_search": [SEARCH_VERIFIED_PRIMARY]}
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    r53 = make_r53()
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: r53)
    patch_dns(monkeypatch)

    with caplog.at_level(logging.INFO):
        assert vd.main() == 0

    assert "DONE" in caplog.text
    r53.change_resource_record_sets.assert_not_called()
    assert not any("/validation/_validate" in url for url, _ in s.post_calls)
    assert not any("/_set_primary" in url for url, _ in s.post_calls)


def test_idempotent_set_primary_only_when_already_verified(monkeypatch, caplog) -> None:
    """Verified but not primary → skip verify steps, just promote primary."""
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    s.post_responses = {
        "/domains/_search": [SEARCH_VERIFIED_NOT_PRIMARY, SEARCH_VERIFIED_PRIMARY],
        "/_set_primary":    [SET_PRIMARY_OK],
    }
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    r53 = make_r53()
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: r53)
    patch_dns(monkeypatch)

    with caplog.at_level(logging.INFO):
        assert vd.main() == 0

    # No verify-side mutations.
    r53.change_resource_record_sets.assert_not_called()
    assert not any("/validation/_generate" in url for url, _ in s.post_calls)
    assert not any("/validation/_validate" in url for url, _ in s.post_calls)
    # Primary was set.
    assert any("/_set_primary" in url for url, _ in s.post_calls)


def test_preflight_fails_on_zitadel_401(monkeypatch) -> None:
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [FakeResponse(401, {}, text="unauthorized")]}
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53())
    patch_dns(monkeypatch)

    with pytest.raises(SystemExit) as exc:
        vd.main()
    assert exc.value.code == 2


def test_preflight_fails_on_route53_access_denied(monkeypatch) -> None:
    from botocore.exceptions import ClientError
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    r53 = MagicMock()
    r53.get_hosted_zone.side_effect = ClientError(
        {"Error": {"Code": "AccessDenied", "Message": "denied"}}, "GetHostedZone"
    )
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: r53)
    patch_dns(monkeypatch)

    with pytest.raises(SystemExit) as exc:
        vd.main()
    assert exc.value.code == 2


def test_aborts_when_domain_not_in_org(monkeypatch) -> None:
    """If the zitadel_domain TF resource hasn't been applied yet, fail clearly."""
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    s.post_responses = {"/domains/_search": [SEARCH_MISSING]}
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53())
    patch_dns(monkeypatch)

    with pytest.raises(SystemExit):
        vd.main()


def test_full_happy_path(monkeypatch, caplog) -> None:
    s = make_happy_session()
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    r53 = make_r53(insync_after=1)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: r53)
    patch_dns(monkeypatch, authoritative_txt=[f'"{TOKEN_VALUE}"'])

    with caplog.at_level(logging.INFO):
        assert vd.main() == 0

    text = caplog.text
    assert "STEP preflight/zitadel-reachable" in text
    assert "STEP idempotency/check-current-status" in text
    assert "STEP generate-challenge" in text
    assert "STEP route53-upsert" in text
    assert "STEP route53-wait-insync" in text
    assert "STEP dns-poll-authoritative" in text
    assert "STEP zitadel-validate" in text
    assert "STEP confirm-verified" in text
    assert "STEP zitadel-set-primary" in text
    assert "STEP confirm-primary" in text
    assert "DONE" in text
    r53.change_resource_record_sets.assert_called_once()
    # Both the verify and primary-flip API calls landed.
    assert any("/validation/_validate" in url for url, _ in s.post_calls)
    assert any("/_set_primary" in url for url, _ in s.post_calls)


def test_dns_propagation_timeout(monkeypatch) -> None:
    s = FakeSession()
    s.get_responses = {"/auth/v1/users/me": [USERS_ME_OK]}
    s.post_responses = {
        "/domains/_search":      [SEARCH_NOT_VERIFIED],
        "/validation/_generate": [GENERATE_OK],
    }
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53(insync_after=1))
    # authoritative resolver always raises — propagation never happens.
    patch_dns(monkeypatch, authoritative_txt=None)
    # Don't actually sleep through the timeout.
    monkeypatch.setattr(vd.time, "sleep", lambda _s: None)

    with pytest.raises(SystemExit):
        vd.main()


def test_validate_retries_on_5xx_then_succeeds(monkeypatch, caplog) -> None:
    s = make_happy_session(validate_5xx_first=True)
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53(insync_after=1))
    patch_dns(monkeypatch, authoritative_txt=[f'"{TOKEN_VALUE}"'])
    monkeypatch.setattr(vd.time, "sleep", lambda _s: None)

    with caplog.at_level(logging.WARNING):
        assert vd.main() == 0

    assert "WARN zitadel-validate attempt=1" in caplog.text


def test_token_never_appears_in_log_output(monkeypatch, caplog) -> None:
    s = make_happy_session()
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53(insync_after=1))
    patch_dns(monkeypatch, authoritative_txt=[f'"{TOKEN_VALUE}"'])

    with caplog.at_level(logging.DEBUG):
        vd.main()

    assert TOKEN_VALUE not in caplog.text, \
        "challenge token leaked into log output — secrets discipline broken"


def test_pat_never_appears_in_log_output(monkeypatch, caplog) -> None:
    s = make_happy_session()
    monkeypatch.setattr(vd, "build_session", lambda _pat: s)
    monkeypatch.setattr(vd.boto3, "client", lambda *_, **__: make_r53(insync_after=1))
    patch_dns(monkeypatch, authoritative_txt=[f'"{TOKEN_VALUE}"'])

    with caplog.at_level(logging.DEBUG):
        vd.main()

    assert PAT_VALUE not in caplog.text, \
        "PAT leaked into log output — secrets discipline broken"


def test_required_env_missing_aborts(monkeypatch) -> None:
    monkeypatch.delenv("DOMAIN", raising=False)
    with pytest.raises(SystemExit):
        vd.main()
