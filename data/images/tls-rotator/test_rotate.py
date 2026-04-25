"""Tests for rotate.py.

Covers expiry parse, skip-when-fresh, renew-when-near-expiry, first-issuance,
lego-failure propagation. Mocks: vault HTTP via vault_read/vault_write
monkeypatch, lego via subprocess monkeypatch.

Run with:

  uv run --with pytest --with cryptography --with boto3 \\
         pytest data/images/tls-rotator/test_rotate.py
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

# Required env must be set before importing rotate (module-level reads).
os.environ.setdefault("VAULT_ADDR", "http://vault.test")
os.environ.setdefault("VAULT_ROLE", "tls-rotator")
os.environ.setdefault("VAULT_MOUNT", "secret")

sys.path.insert(0, str(Path(__file__).parent))
import rotate  # noqa: E402


def _make_cert(days_until_expiry: float) -> tuple[str, str]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test.example.com")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.now(timezone.utc) - timedelta(days=1))
        .not_valid_after(datetime.now(timezone.utc) + timedelta(days=days_until_expiry))
        .sign(key, hashes.SHA256())
    )
    crt_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ).decode()
    return crt_pem, key_pem


@pytest.fixture
def sts_creds():
    return {"AccessKeyId": "a", "SecretAccessKey": "s", "SessionToken": "t", "Region": "us-east-1"}


def test_days_until_expiry_parses_real_cert():
    crt, _ = _make_cert(45.0)
    days = rotate.days_until_expiry(crt)
    assert days is not None
    assert 44.5 < days < 45.5


def test_days_until_expiry_returns_none_on_garbage():
    assert rotate.days_until_expiry("not a cert") is None


def test_days_until_expiry_handles_empty():
    # Defensive: short-circuit if Vault entry has empty pem.
    assert rotate.days_until_expiry("") is None


def test_process_cert_skips_when_fresh(monkeypatch, sts_creds):
    crt, key = _make_cert(60.0)  # well above 30d threshold
    monkeypatch.setattr(rotate, "vault_read", lambda t, p: {"fullchain_pem": crt, "privkey_pem": key})

    write_called = MagicMock()
    monkeypatch.setattr(rotate, "vault_write", write_called)

    fake_subprocess = MagicMock()
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    outcome = rotate.process_cert(
        "tok", sts_creds, "e@x",
        {"name": "n", "domain": "n.example.com", "vault_path": "n/tls"},
    )
    assert outcome == "skipped"
    write_called.assert_not_called()
    fake_subprocess.run.assert_not_called()


def test_process_cert_renews_when_near_expiry(monkeypatch, tmp_path, sts_creds):
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)

    old_crt, old_key = _make_cert(10.0)  # below 30d threshold
    new_crt, new_key = _make_cert(90.0)  # what lego "produces"

    monkeypatch.setattr(rotate, "vault_read", lambda t, p: {"fullchain_pem": old_crt, "privkey_pem": old_key})

    captured = {}
    def fake_write(t, path, data):
        captured["path"] = path
        captured["data"] = data
    monkeypatch.setattr(rotate, "vault_write", fake_write)

    seen = {"args": None}
    def fake_run(args, env, capture_output, text):
        seen["args"] = args
        domain = args[args.index("--domains") + 1]
        d = tmp_path / "certificates"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{domain}.crt").write_text(new_crt)
        (d / f"{domain}.key").write_text(new_key)
        return MagicMock(returncode=0, stdout="ok", stderr="")
    fake_subprocess = MagicMock()
    fake_subprocess.run = fake_run
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    outcome = rotate.process_cert(
        "tok", sts_creds, "e@x",
        {"name": "registry", "domain": "registry.example.com", "vault_path": "registry/tls"},
    )

    assert outcome == "rotated"
    assert captured["path"] == "registry/tls"
    assert captured["data"]["fullchain_pem"] == new_crt
    assert captured["data"]["privkey_pem"] == new_key
    # Always uses `run` — `renew` would need account.json on disk and our
    # emptyDir WORK_DIR doesn't carry that across pod restarts.
    assert "run" in seen["args"]
    assert "renew" not in seen["args"]


def test_process_cert_first_issuance_when_vault_empty(monkeypatch, tmp_path, sts_creds):
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)
    new_crt, new_key = _make_cert(90.0)

    monkeypatch.setattr(rotate, "vault_read", lambda t, p: None)
    monkeypatch.setattr(rotate, "vault_write", lambda t, p, d: None)

    seen = {"args": None}
    def fake_run(args, env, capture_output, text):
        seen["args"] = args
        domain = args[args.index("--domains") + 1]
        d = tmp_path / "certificates"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{domain}.crt").write_text(new_crt)
        (d / f"{domain}.key").write_text(new_key)
        return MagicMock(returncode=0, stdout="ok", stderr="")
    fake_subprocess = MagicMock()
    fake_subprocess.run = fake_run
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    outcome = rotate.process_cert(
        "tok", sts_creds, "e@x",
        {"name": "n", "domain": "n.example.com", "vault_path": "n/tls"},
    )
    assert outcome == "rotated"
    # First issuance uses `run`, not `renew`.
    assert "run" in seen["args"]
    assert "renew" not in seen["args"]


def test_process_cert_propagates_lego_failure(monkeypatch, tmp_path, sts_creds):
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)
    monkeypatch.setattr(rotate, "vault_read", lambda t, p: None)

    fake_subprocess = MagicMock()
    fake_subprocess.run = lambda *a, **kw: MagicMock(returncode=1, stdout="boom", stderr="err")
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    with pytest.raises(RuntimeError, match="lego failed"):
        rotate.process_cert(
            "tok", sts_creds, "e@x",
            {"name": "n", "domain": "n.example.com", "vault_path": "n/tls"},
        )


def test_lego_base_args_injects_sts_session_token(sts_creds):
    args, env = rotate.lego_base_args("e@x", sts_creds)
    assert "--accept-tos" in args
    assert "route53" in args
    assert env["AWS_ACCESS_KEY_ID"] == "a"
    assert env["AWS_SECRET_ACCESS_KEY"] == "s"
    # Critical: lego's Route53 provider needs AWS_SESSION_TOKEN for STS creds.
    assert env["AWS_SESSION_TOKEN"] == "t"
    assert env["AWS_REGION"] == "us-east-1"


def test_main_continues_past_per_cert_failure_and_exits_nonzero(monkeypatch, tmp_path, caplog):
    """One failing cert must not block the others; main returns 1 and
    log.critical is emitted so the Prometheus alert can fire."""
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)
    monkeypatch.setattr(rotate, "vault_login", lambda: "tok")
    monkeypatch.setattr(rotate, "assume_role", lambda c: {"AccessKeyId": "a", "SecretAccessKey": "s", "SessionToken": "t", "Region": "us-east-1"})
    monkeypatch.setattr(rotate, "write_account_key", lambda *a, **kw: None)

    certs = [
        {"name": "good-1", "domain": "g1.example.com", "vault_path": "g1/tls"},
        {"name": "broken", "domain": "b.example.com", "vault_path": "b/tls"},
        {"name": "good-2", "domain": "g2.example.com", "vault_path": "g2/tls"},
    ]
    certs_file = tmp_path / "certs.json"
    certs_file.write_text(__import__("json").dumps(certs))
    monkeypatch.setattr(rotate, "CERTS_FILE", certs_file)

    def fake_vault_read(token, path):
        if path == "tls-rotator/aws":
            return {"aws_access_key_id": "k", "aws_secret_access_key": "s", "aws_region": "us-east-1", "role_arn": "arn:aws:iam::0:role/x"}
        if path == "tls-rotator/acme-account":
            return {"email": "e@x", "account_key_pem": "PRIV"}
        # Per-cert: return None so process_cert takes the "first issuance" branch.
        return None
    monkeypatch.setattr(rotate, "vault_read", fake_vault_read)

    written = []
    monkeypatch.setattr(rotate, "vault_write", lambda t, p, d: written.append(p))

    new_crt, new_key = _make_cert(90.0)
    def fake_run(args, env, capture_output, text):
        domain = args[args.index("--domains") + 1]
        if domain == "b.example.com":
            return MagicMock(returncode=1, stdout="", stderr="DNS01 failure")
        d = tmp_path / "certificates"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{domain}.crt").write_text(new_crt)
        (d / f"{domain}.key").write_text(new_key)
        return MagicMock(returncode=0, stdout="ok", stderr="")
    fake_subprocess = MagicMock()
    fake_subprocess.run = fake_run
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    import logging as _logging
    with caplog.at_level(_logging.CRITICAL, logger="tls-rotator"):
        rc = rotate.main()

    assert rc == 1
    # The two healthy certs were rotated even though the middle one failed.
    assert "g1/tls" in written
    assert "g2/tls" in written
    assert "b/tls" not in written
    # Per-cert failure logged at CRITICAL with the cert name in the message.
    crit_messages = [r.getMessage() for r in caplog.records if r.levelno == _logging.CRITICAL]
    assert any("broken" in m for m in crit_messages)


def test_cert_info_extracts_public_fields():
    crt, _ = _make_cert(45.0)
    info = rotate.cert_info(crt)
    assert info is not None
    assert "test.example.com" in info["subject"]
    assert "test.example.com" in info["issuer"]  # self-signed
    assert info["issued_at"] < info["expires_at"]
    assert info["serial"]  # non-empty hex


def test_cert_info_returns_none_on_garbage():
    assert rotate.cert_info("not a cert") is None


def test_process_cert_logs_current_and_new_at_info(monkeypatch, tmp_path, sts_creds, caplog):
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)

    old_crt, old_key = _make_cert(10.0)
    new_crt, new_key = _make_cert(90.0)

    monkeypatch.setattr(rotate, "vault_read", lambda t, p: {"fullchain_pem": old_crt, "privkey_pem": old_key})
    monkeypatch.setattr(rotate, "vault_write", lambda t, p, d: None)

    def fake_run(args, env, capture_output, text):
        domain = args[args.index("--domains") + 1]
        d = tmp_path / "certificates"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{domain}.crt").write_text(new_crt)
        (d / f"{domain}.key").write_text(new_key)
        return MagicMock(returncode=0, stdout="ok", stderr="")
    fake_subprocess = MagicMock()
    fake_subprocess.run = fake_run
    monkeypatch.setattr(rotate, "subprocess", fake_subprocess)

    import logging as _logging
    with caplog.at_level(_logging.INFO, logger="tls-rotator"):
        rotate.process_cert("tok", sts_creds, "e@x",
                            {"name": "registry", "domain": "registry.example.com", "vault_path": "registry/tls"})

    msgs = [r.getMessage() for r in caplog.records if r.name == "tls-rotator"]
    # Both before-rotation and after-rotation cert info lines emitted.
    assert any(m.startswith("current registry:") and "subject=" in m for m in msgs)
    assert any(m.startswith("new     registry:") and "subject=" in m for m in msgs)


def test_write_account_key_layout(tmp_path, monkeypatch):
    monkeypatch.setattr(rotate, "WORK_DIR", tmp_path)
    monkeypatch.setattr(rotate, "ACME_SERVER", "https://acme-v02.api.letsencrypt.org/directory")
    rotate.write_account_key("user@example.com", "PRIV-KEY-PEM")
    p = tmp_path / "accounts" / "acme-v02.api.letsencrypt.org" / "user@example.com" / "keys" / "user@example.com.key"
    assert p.exists()
    assert p.read_text() == "PRIV-KEY-PEM"
