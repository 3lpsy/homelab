"""Tests for data/scripts/registry-htpasswd-ssha.py.

Verifies the generated nginx {SSHA} entries validate the way nginx does
(base64-decode → last bytes are the salt → sha1(pw+salt) == leading bytes),
that empty/non-matching files are skipped, and that an empty source dir is a
hard error (never write an empty htpasswd → would lock everyone out).

Run: uv run --with pytest pytest data/scripts/test_registry_htpasswd_ssha.py
"""
from __future__ import annotations

import base64
import hashlib
import importlib.util
from pathlib import Path

import pytest

# Hyphenated filename -> can't `import registry-htpasswd-ssha`.
spec = importlib.util.spec_from_file_location(
    "registry_htpasswd_ssha", Path(__file__).parent / "registry-htpasswd-ssha.py"
)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def nginx_verify(entry: str, password: bytes) -> bool:
    """Validate a `<user>:{SSHA}<b64>` entry exactly as nginx does."""
    _, h = entry.split(":", 1)
    raw = base64.b64decode(h[len("{SSHA}"):])
    digest, salt = raw[:20], raw[20:]
    return hashlib.sha1(password + salt).digest() == digest


def test_ssha_validates_and_rejects():
    h = mod.ssha(b"a-32char-random-password-example")
    assert nginx_verify("u:" + h, b"a-32char-random-password-example")
    assert not nginx_verify("u:" + h, b"wrong-password")


def test_ssha_salt_is_random_per_call():
    # Two calls on the same password must differ (random salt) yet both verify.
    a = mod.ssha(b"same")
    b = mod.ssha(b"same")
    assert a != b
    assert nginx_verify("u:" + a, b"same") and nginx_verify("u:" + b, b"same")


def test_build_multi_user_skips_empty_and_nonmatching(tmp_path):
    (tmp_path / "password_internal").write_text("pw-internal-xyz")
    (tmp_path / "password_forgejo-runner").write_text("pw-forgejo-123\n")  # trailing \n stripped
    (tmp_path / "password_empty").write_text("")        # skipped: empty
    (tmp_path / "tls_crt").write_text("not-a-password")  # skipped: no prefix

    lines = mod.build(tmp_path)
    users = sorted(line.split(":", 1)[0] for line in lines)
    assert users == ["forgejo-runner", "internal"]

    by_user = {line.split(":", 1)[0]: line for line in lines}
    assert nginx_verify(by_user["internal"], b"pw-internal-xyz")
    assert nginx_verify(by_user["forgejo-runner"], b"pw-forgejo-123")  # whitespace-stripped


def test_main_writes_file(tmp_path, monkeypatch):
    src = tmp_path / "src"
    src.mkdir()
    (src / "password_internal").write_text("secret")
    out = tmp_path / "out" / "htpasswd"
    monkeypatch.setenv("HTPASSWD_SRC_DIR", str(src))
    monkeypatch.setenv("HTPASSWD_OUT_FILE", str(out))

    assert mod.main() == 0
    content = out.read_text()
    assert content.startswith("internal:{SSHA}") and content.endswith("\n")
    assert nginx_verify(content.strip(), b"secret")


def test_main_refuses_empty_source(tmp_path, monkeypatch):
    src = tmp_path / "src"
    src.mkdir()  # no password_* files
    out = tmp_path / "out" / "htpasswd"
    monkeypatch.setenv("HTPASSWD_SRC_DIR", str(src))
    monkeypatch.setenv("HTPASSWD_OUT_FILE", str(out))

    assert mod.main() == 1          # hard error
    assert not out.exists()         # never wrote an empty htpasswd
