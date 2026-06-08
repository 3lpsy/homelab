"""Tests for data/headscale/headscale-oidc-watchdog.sh.tpl.

Renders the Terraform templatefile() source the way Terraform would, then
runs the resulting bash script against stubbed host commands (headscale,
systemctl, curl, journalctl, logger, sleep) on a temp PATH. Health is made
stateful via a file the `headscale` stub reads and the `systemctl` stub
flips on `restart headscale`, so the park/restore dances can be exercised
end to end without root or a real headscale.

Run: uv run pytest data/headscale/test_headscale_oidc_watchdog.py
"""

import os
import stat
import subprocess
from pathlib import Path

TPL = Path(__file__).with_name("headscale-oidc-watchdog.sh.tpl")


def render(tpl_text: str, magic_fqdn_suffix: str) -> str:
    """Mimic Terraform templatefile(): interpolate the one var, then
    collapse the doubled escapes ($${ -> ${, %%{ -> %{)."""
    return (
        tpl_text.replace("${magic_fqdn_suffix}", magic_fqdn_suffix)
        .replace("$${", "${")
        .replace("%%{", "%{")
    )


def _write_exec(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IRWXU)


def make_stubs(bindir: Path, state: Path) -> None:
    """Stub the external commands the script calls.

    health is read from `state` ("up"/"down"); `systemctl restart
    headscale` writes "up" (a real restart breaks the OIDC deadlock once
    the slice is parked). curl returns $ZITADEL_CODE. journalctl prints
    $JOURNAL_TEXT. sleep/logger/pin are no-ops. Calls are appended to
    $CALLS for assertions.
    """
    _write_exec(
        bindir / "headscale",
        '#!/usr/bin/env bash\n'
        'echo "headscale $*" >> "$CALLS"\n'
        '# only `nodes list` is used as the health probe\n'
        'if [ "$1" = nodes ]; then\n'
        '  [ "$(cat "$HS_STATE")" = up ] && exit 0 || exit 1\n'
        'fi\n'
        'exit 0\n',
    )
    _write_exec(
        bindir / "systemctl",
        '#!/usr/bin/env bash\n'
        'echo "systemctl $*" >> "$CALLS"\n'
        'if [ "$1" = restart ]; then echo up > "$HS_STATE"; fi\n'
        'exit 0\n',
    )
    _write_exec(
        bindir / "curl",
        '#!/usr/bin/env bash\n'
        'echo "curl $*" >> "$CALLS"\n'
        'printf "%s" "${ZITADEL_CODE:-000}"\n'
        'exit 0\n',
    )
    _write_exec(
        bindir / "journalctl",
        '#!/usr/bin/env bash\nprintf "%s\\n" "${JOURNAL_TEXT:-}"\nexit 0\n',
    )
    _write_exec(bindir / "logger", '#!/usr/bin/env bash\nexit 0\n')
    _write_exec(bindir / "sleep", '#!/usr/bin/env bash\nexit 0\n')
    state.write_text("down")


def run(tmp_path: Path, *, health: str, slice_present: bool, parked_present: bool,
        journal: str = "", zitadel_code: str = "000"):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    hs_state = tmp_path / "hs_state"
    calls = tmp_path / "calls"
    calls.write_text("")
    make_stubs(bindir, hs_state)
    hs_state.write_text(health)

    slice_p = tmp_path / "_oidc.yaml"
    parked_p = tmp_path / "_oidc.yaml.disabled"
    if slice_present:
        slice_p.write_text("oidc:\n  issuer: x\n")
    if parked_present:
        parked_p.write_text("oidc:\n  issuer: x\n")

    script = tmp_path / "watchdog.sh"
    script.write_text(render(TPL.read_text()))
    script.chmod(0o755)

    env = {
        **os.environ,
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "HS_STATE": str(hs_state),
        "CALLS": str(calls),
        "JOURNAL_TEXT": journal,
        "ZITADEL_CODE": zitadel_code,
        "HEADSCALE_OIDC_SLICE": str(slice_p),
        "HEADSCALE_OIDC_PARKED": str(parked_p),
        "HEADSCALE_OIDC_PIN": str(bindir / "logger"),  # no-op stand-in
        "HEADSCALE_OIDC_LOCK": str(tmp_path / "wd.lock"),
        "HEADSCALE_OIDC_DISCOVERY": "https://oidc.test/.well-known/openid-configuration",
    }
    proc = subprocess.run(
        ["bash", str(script)], env=env, capture_output=True, text=True, timeout=30,
    )
    return proc, slice_p, parked_p, calls.read_text()


# ── Branch B: normal (slice in place) ──────────────────────────────────

def test_healthy_noop(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="up", slice_present=True, parked_present=False)
    assert proc.returncode == 0
    assert slice_p.exists() and not parked_p.exists()
    assert "restart" not in calls  # never touched the service


def test_healthy_clears_stale_park(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="up", slice_present=True, parked_present=True)
    assert proc.returncode == 0
    assert not parked_p.exists()  # stale park file removed
    assert slice_p.exists()


def test_down_with_oidc_error_parks(tmp_path):
    # down before restart; systemctl restart flips health up (deadlock broken)
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="down", slice_present=True, parked_present=False,
        journal="FTL creating OIDC provider from issuer config")
    assert proc.returncode == 0
    assert parked_p.exists() and not slice_p.exists()  # slice parked
    assert "systemctl restart headscale" in calls
    assert "up OIDC-less" in proc.stdout


def test_down_without_oidc_error_no_action(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="down", slice_present=True, parked_present=False,
        journal="some unrelated crash")
    assert proc.returncode == 0
    assert slice_p.exists() and not parked_p.exists()  # untouched
    assert "not intervening" in proc.stdout
    assert "restart" not in calls


def test_down_oidc_error_but_no_slice(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="down", slice_present=False, parked_present=False,
        journal="creating OIDC provider")
    assert proc.returncode == 0
    assert "nothing to park" in proc.stdout
    assert "restart" not in calls


# ── Branch A: OIDC parked by a prior run ───────────────────────────────

def test_parked_zitadel_up_restores(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="up", slice_present=False, parked_present=True,
        zitadel_code="200")
    assert proc.returncode == 0
    assert slice_p.exists() and not parked_p.exists()  # restored
    assert "systemctl restart headscale" in calls
    assert "restoring OIDC slice" in proc.stdout


def test_parked_zitadel_down_stays_parked(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="up", slice_present=False, parked_present=True,
        zitadel_code="000")
    assert proc.returncode == 0
    assert parked_p.exists() and not slice_p.exists()  # still parked
    assert "restart" not in calls
    assert "retry next cycle" in proc.stdout


def test_parked_headscale_still_down_bails(tmp_path):
    proc, slice_p, parked_p, calls = run(
        tmp_path, health="down", slice_present=False, parked_present=True,
        zitadel_code="200")
    assert proc.returncode == 1
    assert parked_p.exists() and not slice_p.exists()
    assert "leaving for ops" in proc.stdout
