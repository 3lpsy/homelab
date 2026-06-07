"""Tests for data/images/git-runner/register.sh:maybe_register.

Sources the function and runs it against stubbed curl/jq/forgejo-runner on a
temp PATH, asserting the registration decision + the user-scoped token call.

Run: uv run --with pytest pytest data/images/git-runner/test_register.py
"""

import os
import stat
import subprocess
from pathlib import Path

REGISTER_SH = Path(__file__).with_name("register.sh")


def _write_exec(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IRWXU)


def make_stubs(bindir: Path, *, curl_fails: bool) -> None:
    # curl: record args, then either fail or emit a token JSON.
    if curl_fails:
        curl_body = '#!/usr/bin/env bash\necho "curl $*" >> "$CALLS"\nexit 1\n'
    else:
        curl_body = (
            '#!/usr/bin/env bash\n'
            'echo "curl $*" >> "$CALLS"\n'
            'printf \'{"token":"abc123"}\'\n'
        )
    _write_exec(bindir / "curl", curl_body)
    # jq: record + emit a fixed token (decouples the test from a real jq).
    _write_exec(
        bindir / "jq",
        '#!/usr/bin/env bash\necho "jq $*" >> "$CALLS"\ncat >/dev/null\nprintf abc123\n',
    )
    # forgejo-runner: record the register invocation.
    _write_exec(
        bindir / "forgejo-runner",
        '#!/usr/bin/env bash\necho "forgejo-runner $*" >> "$CALLS"\nexit 0\n',
    )


def run(tmp_path: Path, *, runner_file_exists: bool, curl_fails: bool = False):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    calls = tmp_path / "calls"
    calls.write_text("")
    make_stubs(bindir, curl_fails=curl_fails)

    runner_file = tmp_path / ".runner"
    if runner_file_exists:
        runner_file.write_text("{}")

    env = {
        **os.environ,
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "CALLS": str(calls),
        "RUNNER_FILE": str(runner_file),
        "GIT_FQDN": "git.test.example",
        "PERSONAL_USER": "testuser",
        "FORGEJO_ADMIN_PASSWORD": "s3cret",
        "RUNNER_LABELS": "ubuntu-latest:docker://img",
    }
    script = f"set -euo pipefail; . {REGISTER_SH}; maybe_register"
    proc = subprocess.run(
        ["bash", "-c", script], env=env, capture_output=True, text=True, timeout=30,
    )
    return proc, calls.read_text()


def test_already_registered_skips(tmp_path):
    proc, calls = run(tmp_path, runner_file_exists=True)
    assert proc.returncode == 0
    assert "forgejo-runner register" not in calls
    assert "curl" not in calls


def test_registers_user_scoped(tmp_path):
    proc, calls = run(tmp_path, runner_file_exists=False)
    assert proc.returncode == 0, proc.stderr
    # user-scoped token endpoint + Sudo header for the personal user
    assert "/api/v1/user/actions/runners/registration-token" in calls
    assert "Sudo: testuser" in calls
    # registered against the right instance/name/labels
    assert "forgejo-runner register" in calls
    assert "--instance https://git.test.example" in calls
    assert "--name git-runner" in calls
    assert "--labels ubuntu-latest:docker://img" in calls


def test_token_fetch_failure_aborts(tmp_path):
    proc, calls = run(tmp_path, runner_file_exists=False, curl_fails=True)
    assert proc.returncode != 0
    assert "forgejo-runner register" not in calls  # never reached
