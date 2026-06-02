"""Tests for read-k3s-token.py.

Verifies the contracts that matter operationally:
  - the SSH command targets the right host/user and cats the server node-token
  - the returned token is stripped of trailing whitespace/newline
  - an empty token fails loudly (don't hand k3s an empty K3S_TOKEN)
  - main() shapes stdout as the {"token": ...} JSON data.external expects
  - main() rejects a query missing required fields

Run with:

  uv run --with pytest pytest data/scripts/test_read_k3s_token.py
"""
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path

import pytest


# Hyphenated filename -> can't `import read-k3s-token`.
spec = importlib.util.spec_from_file_location(
    "read_k3s_token", Path(__file__).parent / "read-k3s-token.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class _FakeCompleted:
    def __init__(self, stdout):
        self.stdout = stdout


def _runner_returning(stdout, calls=None):
    def runner(cmd, **kwargs):
        if calls is not None:
            calls.append((cmd, kwargs))
        return _FakeCompleted(stdout)

    return runner


def test_read_token_strips_trailing_newline():
    calls = []
    runner = _runner_returning("K10abc::server:def456\n", calls)
    token = mod.read_token("delphi.hs.example.com", "provisioner", "/k.pem", runner=runner)
    assert token == "K10abc::server:def456"


def test_read_token_builds_expected_ssh_command():
    calls = []
    runner = _runner_returning("tok\n", calls)
    mod.read_token("delphi.hs.example.com", "provisioner", "/keys/id", runner=runner)
    cmd, kwargs = calls[0]
    assert cmd[0] == "ssh"
    assert "provisioner@delphi.hs.example.com" in cmd
    assert "-i" in cmd and "/keys/id" in cmd
    assert f"sudo cat {mod.TOKEN_PATH}" in cmd
    # check=True so a non-zero exit (no token / no sudo) surfaces as an error.
    assert kwargs.get("check") is True
    assert kwargs.get("capture_output") is True


def test_read_token_empty_raises():
    runner = _runner_returning("   \n")
    with pytest.raises(ValueError):
        mod.read_token("h", "u", "/k", runner=runner)


def test_main_emits_token_json(monkeypatch):
    monkeypatch.setattr(mod, "read_token", lambda h, u, k: "THE-TOKEN")
    stdin = io.StringIO(json.dumps({
        "host": "delphi.hs.example.com",
        "ssh_user": "provisioner",
        "ssh_key_path": "/k.pem",
    }))
    stdout = io.StringIO()
    mod.main(stdin=stdin, stdout=stdout)
    assert json.loads(stdout.getvalue()) == {"token": "THE-TOKEN"}


def test_main_missing_field_raises():
    stdin = io.StringIO(json.dumps({"host": "h", "ssh_user": "u"}))  # no ssh_key_path
    with pytest.raises(KeyError):
        mod.main(stdin=stdin, stdout=io.StringIO())
