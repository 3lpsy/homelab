"""Tests for provisioner.py.

Covers the destination credential expansion path: ${NTFY_BASIC_B64} placeholder
in destination JSON must be replaced at runtime from NTFY_USER + NTFY_PASSWORD,
and must NOT remain literal in what gets POSTed to OpenObserve. This is the
fix that keeps the basic-auth credential out of the ConfigMap (and out of
Velero backups in S3).

Run with:

  uv run --with pytest pytest data/openobserve/test_provisioner.py
"""
from __future__ import annotations

import base64
import json
import os
import sys
from pathlib import Path

import pytest

# provisioner.py reads OO_URL/OO_ORG/OO_AUTH/CONFIG_DIR at import time.
os.environ.setdefault("OO_URL", "http://oo.test:5080")
os.environ.setdefault("OO_ORG", "default")
os.environ.setdefault("OO_AUTH", "dGVzdDp0ZXN0")  # test:test
os.environ.setdefault("CONFIG_DIR", "/tmp/oo-test-cfg")

sys.path.insert(0, str(Path(__file__).parent))
import provisioner  # noqa: E402


@pytest.fixture
def config_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(provisioner, "CONFIG_DIR", tmp_path)
    return tmp_path


@pytest.fixture(autouse=True)
def _clear_ntfy_env(monkeypatch):
    for k in ("NTFY_USER", "NTFY_PASSWORD", "NTFY_BASIC_B64"):
        monkeypatch.delenv(k, raising=False)


def _write_dest(config_dir: Path, body: str) -> None:
    d = config_dir / "destinations"
    d.mkdir(parents=True, exist_ok=True)
    (d / "ntfy.json").write_text(body)


def test_derive_ntfy_basic_b64_sets_env(monkeypatch):
    monkeypatch.setenv("NTFY_USER", "openobserve")
    monkeypatch.setenv("NTFY_PASSWORD", "hunter2")
    provisioner.derive_ntfy_basic_b64()
    expected = base64.b64encode(b"openobserve:hunter2").decode()
    assert os.environ["NTFY_BASIC_B64"] == expected


def test_derive_ntfy_basic_b64_skips_when_missing(monkeypatch):
    # Only password set, user missing — must not populate placeholder.
    monkeypatch.setenv("NTFY_PASSWORD", "hunter2")
    provisioner.derive_ntfy_basic_b64()
    assert "NTFY_BASIC_B64" not in os.environ


def test_load_jsons_substitutes_env_in_destinations(config_dir, monkeypatch):
    _write_dest(config_dir, json.dumps({
        "name": "ntfy",
        "headers": {"Authorization": "Basic ${NTFY_BASIC_B64}"},
    }))
    monkeypatch.setenv("NTFY_BASIC_B64", "ZXhwYW5kZWQ=")

    [(name, body)] = provisioner.load_jsons("destinations", substitute_env=True)

    assert name == "ntfy"
    assert body["headers"]["Authorization"] == "Basic ZXhwYW5kZWQ="


def test_load_jsons_no_substitution_when_flag_off(config_dir, monkeypatch):
    # Without substitute_env=True, ${VAR} must remain literal so we never
    # accidentally expand env into dashboards / alerts / templates.
    _write_dest(config_dir, json.dumps({
        "name": "ntfy",
        "headers": {"Authorization": "Basic ${NTFY_BASIC_B64}"},
    }))
    monkeypatch.setenv("NTFY_BASIC_B64", "ZXhwYW5kZWQ=")

    [(_, body)] = provisioner.load_jsons("destinations", substitute_env=False)

    assert body["headers"]["Authorization"] == "Basic ${NTFY_BASIC_B64}"


def test_load_jsons_safe_substitute_leaves_unknown_var(config_dir):
    # safe_substitute is non-fatal on missing vars — keeps placeholder literal
    # so the JSON still parses and the failure is visible at API call time
    # rather than during file load.
    _write_dest(config_dir, json.dumps({
        "name": "ntfy",
        "headers": {"Authorization": "Basic ${NTFY_BASIC_B64}"},
    }))
    # NTFY_BASIC_B64 cleared by autouse fixture.

    [(_, body)] = provisioner.load_jsons("destinations", substitute_env=True)

    assert body["headers"]["Authorization"] == "Basic ${NTFY_BASIC_B64}"


def test_end_to_end_real_template(config_dir, monkeypatch):
    # Render the actual template string the way Terraform would, then verify
    # that derive + load_jsons together produce a valid Authorization header.
    template_path = (
        Path(__file__).parent / "alerts" / "destinations" / "ntfy.json.tpl"
    )
    rendered = template_path.read_text()
    # Mimic templatefile()'s `$${VAR}` -> `${VAR}` and substitute the two
    # actual TF vars (ntfy_url, ntfy_priority).
    rendered = (
        rendered
        .replace("$${", "${")
        .replace("${ntfy_url}", "http://ntfy.monitoring.svc.cluster.local:8080/topic")
        .replace("${ntfy_priority}", "default")
    )
    _write_dest(config_dir, rendered)

    monkeypatch.setenv("NTFY_USER", "openobserve")
    monkeypatch.setenv("NTFY_PASSWORD", "s3cret")
    provisioner.derive_ntfy_basic_b64()

    [(_, body)] = provisioner.load_jsons("destinations", substitute_env=True)

    expected_b64 = base64.b64encode(b"openobserve:s3cret").decode()
    assert body["headers"]["Authorization"] == f"Basic {expected_b64}"
    assert body["url"] == "http://ntfy.monitoring.svc.cluster.local:8080/topic"
