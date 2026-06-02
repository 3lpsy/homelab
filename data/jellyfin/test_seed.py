"""Tests for jellyfin/seed.py.

Covers:
  - section_hash stability + order-independence for sets/dicts
  - desired_seed_policy / desired_user_policy: merge semantics
  - desired_sso_config: includes Zitadel aud-mapping scope
  - redact_sso: sensitive keys replaced
  - load/save_seed_state: round-trip + atomic write + missing-file tolerance
  - section_cached: positive + negative
  - reconcile_sso_plugin: skip-if-cached + happy path
  - reconcile_users: create-vs-existing branches, password reset, admin policy
  - read_secret: raises on missing file
  - _is_transient_network_error: matches expected errnos
  - Settings.from_env: missing USERS aborts; happy path

Run with:

  uv run --with pytest pytest data/jellyfin/test_seed.py
"""
from __future__ import annotations

import json
import urllib.error
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

import seed


CLIENT_ID = "client-id-abc"
CLIENT_SECRET = "client-secret-do-not-log"
SEED_PASSWORD = "seed-pw-do-not-log"
SEED_USER_ID = "seed-user-uuid"
PERSONAL_USER_ID = "personal-uuid"
PARTNER_USER_ID = "partner-uuid"
ISSUER = "https://oidc.example"


# --- helpers ---------------------------------------------------------------

def _settings(tmp_path: Path, **overrides: Any) -> seed.Settings:
    base = dict(
        jellyfin_url="http://jellyfin:8096",
        jellyfin_public_url="https://jellyfin.example",
        users=["jim", "tara"],
        admin_users=["jim"],
        seed_user="_seed",
        secrets_dir=tmp_path,
        seed_state_path=tmp_path / "seed" / "state.json",
        oidc_provider="zitadel",
        oidc_issuer_url=ISSUER,
        oidc_button_text="Login with Zitadel",
    )
    base.update(overrides)
    return seed.Settings(**base)


def _empty_state() -> dict:
    return {"version": seed.STATE_VERSION, "sections": {}}


def _write_secrets(secrets_dir: Path, *,
                   seed_pw: str = SEED_PASSWORD,
                   client_id: str = CLIENT_ID,
                   client_secret: str = CLIENT_SECRET,
                   admin_passwords: dict[str, str] | None = None) -> None:
    (secrets_dir / "seed_admin_password").write_text(seed_pw)
    (secrets_dir / "oidc_client_id").write_text(client_id)
    (secrets_dir / "oidc_client_secret").write_text(client_secret)
    for u, pw in (admin_passwords or {"jim": "jim-vault-pw"}).items():
        (secrets_dir / f"password_{u}").write_text(pw)


def _client() -> MagicMock:
    """MagicMock spec'd to JellyfinClient with sensible default returns."""
    return MagicMock(spec=seed.JellyfinClient)


# --- section_hash ----------------------------------------------------------

def test_section_hash_stable() -> None:
    a = seed.section_hash("a", {"x": 1}, [1, 2])
    b = seed.section_hash("a", {"x": 1}, [1, 2])
    assert a == b


def test_section_hash_dict_key_order_invariant() -> None:
    a = seed.section_hash({"x": 1, "y": 2})
    b = seed.section_hash({"y": 2, "x": 1})
    assert a == b


def test_section_hash_changes_with_input() -> None:
    a = seed.section_hash("a")
    b = seed.section_hash("b")
    assert a != b


# --- policy composers ------------------------------------------------------

def test_desired_seed_policy_preserves_unknown_fields() -> None:
    current = {"FutureField": "keep me", "IsAdministrator": False, "IsHidden": False}
    out = seed.desired_seed_policy(current)
    assert out["IsAdministrator"] is True
    assert out["IsHidden"] is True
    assert out["EnableUserPreferenceAccess"] is False
    assert out["IsDisabled"] is False
    assert out["FutureField"] == "keep me"


def test_desired_user_policy_admin_vs_regular() -> None:
    admin = seed.desired_user_policy({}, is_admin=True)
    regular = seed.desired_user_policy({}, is_admin=False)
    assert admin["IsAdministrator"] is True
    assert regular["IsAdministrator"] is False
    for p in (admin, regular):
        assert p["IsHidden"] is False
        assert p["IsDisabled"] is False
        assert p["EnableAllFolders"] is True


# --- SSO config composer + redaction --------------------------------------

def test_desired_sso_config_shape(tmp_path: Path) -> None:
    """Verify the OidConfig payload matches v4.0.0.4's actual schema."""
    s = _settings(tmp_path)
    cfg = seed.desired_sso_config(s, CLIENT_ID, CLIENT_SECRET)
    assert cfg["OidClientId"] == CLIENT_ID
    assert cfg["OidSecret"] == CLIENT_SECRET
    assert cfg["OidEndpoint"] == ISSUER
    assert cfg["DefaultProvider"] == "zitadel"
    assert cfg["DefaultUsernameClaim"] == "preferred_username"
    assert cfg["Enabled"] is True
    # MUST be False — true causes the plugin to demote the user to
    # non-admin on every OIDC login (empty AdminRoles → isAdmin=false →
    # SetPermission(IsAdministrator, false)). See seed.py docstring.
    assert cfg["EnableAuthorization"] is False
    # NewPath=true pins the plugin to /sso/OID/redirect/<provider> as the
    # advertised redirect URI (vs /sso/OID/r/<provider>) — must match the
    # URI registered with Zitadel.
    assert cfg["NewPath"] is True
    # SchemeOverride=https is REQUIRED — Jellyfin lives behind a
    # TLS-terminating nginx sidecar and sees request scheme as plain
    # http. Without this override the plugin emits an http:// redirect
    # URI which Zitadel rejects ("redirect_uri is missing in the client
    # configuration").
    assert cfg["SchemeOverride"] == "https"
    # Standard OIDC scopes only — the plugin tolerates extra entries in
    # the issued aud claim, so no Zitadel-specific aud-mapping scope.
    assert cfg["OidScopes"] == ["openid", "email", "profile"]


def test_desired_sso_config_no_unknown_fields(tmp_path: Path) -> None:
    """Guard against drifting back into payload keys the plugin rejects.
    `NewUserPolicy` doesn't exist in v4.0.0.4's OidConfig — a JSON body
    containing it will be silently dropped, but listing it here would
    mislead future readers."""
    s = _settings(tmp_path)
    cfg = seed.desired_sso_config(s, CLIENT_ID, CLIENT_SECRET)
    assert "NewUserPolicy" not in cfg
    # Sanity: CanonicalLinks is a dict (SerializableDictionary), not a list.
    assert isinstance(cfg["CanonicalLinks"], dict)


def test_redact_sso_replaces_sensitive_keys() -> None:
    cfg = {
        "OidClientId":  CLIENT_ID,
        "OidSecret":    CLIENT_SECRET,
        "Enabled":      True,
        "OidEndpoint":  ISSUER,
    }
    red = seed.redact_sso(cfg)
    assert red["OidClientId"] == "<redacted>"
    assert red["OidSecret"] == "<redacted>"
    assert red["Enabled"] is True
    assert red["OidEndpoint"] == ISSUER


# --- state-cache I/O -------------------------------------------------------

def test_load_seed_state_missing_returns_empty(tmp_path: Path) -> None:
    state = seed.load_seed_state(tmp_path / "missing.json")
    assert state == _empty_state()


def test_load_seed_state_corrupt_treated_as_empty(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    path.write_text("{not json")
    state = seed.load_seed_state(path)
    assert state == _empty_state()


def test_save_then_load_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    state = _empty_state()
    seed.record_section(state, "sso_plugin", "deadbeef")
    seed.save_seed_state(path, state)

    loaded = seed.load_seed_state(path)
    assert loaded["sections"]["sso_plugin"]["hash"] == "deadbeef"


def test_save_seed_state_creates_parent_subdir(tmp_path: Path) -> None:
    """Seed-state path must NOT live at the jellyfin /config root —
    Jellyfin's BaseApplicationPaths.MakeSanityCheckOrThrow rejects
    unknown `.jellyfin-*` markers there. The configured path is a subdir
    (`/jf-config/seed/state.json`); save_seed_state must create the
    intermediate dir automatically (incident 2026-05-09)."""
    path = tmp_path / "seed" / "state.json"
    assert not path.parent.exists()
    state = _empty_state()
    seed.record_section(state, "sso_plugin", "abc123")
    seed.save_seed_state(path, state)
    assert path.parent.is_dir()
    assert path.is_file()
    loaded = seed.load_seed_state(path)
    assert loaded["sections"]["sso_plugin"]["hash"] == "abc123"


def test_save_seed_state_skips_when_path_empty(tmp_path: Path) -> None:
    """An empty Path() means caching is disabled — save must be a no-op."""
    seed.save_seed_state(Path(""), {"sections": {}})  # would crash if it tried


def test_section_cached_positive_and_negative() -> None:
    state = _empty_state()
    seed.record_section(state, "sso_plugin", "h1")
    assert seed.section_cached(state, "sso_plugin", "h1")
    assert not seed.section_cached(state, "sso_plugin", "h2")
    assert not seed.section_cached(state, "missing", "h1")


# --- reconcile_sso_plugin --------------------------------------------------

def test_reconcile_sso_plugin_empty_issuer_is_noop(tmp_path: Path) -> None:
    s = _settings(tmp_path, oidc_issuer_url="")
    c = _client()
    state = _empty_state()
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.assert_not_called()


def test_reconcile_sso_plugin_missing_secrets_aborts(tmp_path: Path) -> None:
    s = _settings(tmp_path)  # secrets_dir=tmp_path, but no files
    c = _client()
    with pytest.raises(seed.JellyfinError, match="missing secret"):
        seed.reconcile_sso_plugin(c, s, _empty_state())
    c.sso_set_provider.assert_not_called()


def test_reconcile_sso_plugin_happy_path(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    _write_secrets(tmp_path)
    c = _client()
    state = _empty_state()
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.assert_called_once()
    args, _ = c.sso_set_provider.call_args
    provider, payload = args
    assert provider == "zitadel"
    assert payload["OidClientId"] == CLIENT_ID
    assert payload["OidSecret"] == CLIENT_SECRET
    # Hash must be persisted so a re-run is a no-op.
    assert "sso_plugin" in state["sections"]


def test_reconcile_sso_plugin_steady_state_skips(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    _write_secrets(tmp_path)
    c = _client()
    state = _empty_state()
    # First run lands the hash.
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.reset_mock()
    # Second run with same inputs — no POST.
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.assert_not_called()


def test_reconcile_sso_plugin_secret_rotation_re_runs(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    _write_secrets(tmp_path)
    c = _client()
    state = _empty_state()
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.reset_mock()

    # Rotate the client_secret on disk → hash flips → re-POST.
    (tmp_path / "oidc_client_secret").write_text("new-secret")
    seed.reconcile_sso_plugin(c, s, state)
    c.sso_set_provider.assert_called_once()


# --- reconcile_branding ---------------------------------------------------

def test_desired_branding_injects_form_with_public_url(tmp_path: Path) -> None:
    s = _settings(tmp_path,
                  jellyfin_public_url="https://jellyfin.example.com/",
                  oidc_provider="zitadel",
                  oidc_button_text="Login with Zitadel")
    out = seed.desired_branding(s, current={})
    # Form action must be the PUBLIC URL (browser-side), not the
    # cluster-internal one. Trailing slash on input is normalized.
    assert "https://jellyfin.example.com/sso/OID/start/zitadel" in out["LoginDisclaimer"]
    assert "Login with Zitadel" in out["LoginDisclaimer"]
    # CSS must be present too — without it the button overlaps the
    # standard login form.
    assert "raised.emby-button" in out["CustomCss"]


def test_desired_branding_preserves_unknown_fields(tmp_path: Path) -> None:
    """A future Jellyfin Branding field shouldn't get clobbered."""
    s = _settings(tmp_path)
    current = {
        "SplashscreenEnabled": True,
        "FutureUnknownKnob": "preserve-me",
    }
    out = seed.desired_branding(s, current)
    assert out["SplashscreenEnabled"] is True
    assert out["FutureUnknownKnob"] == "preserve-me"


def test_reconcile_branding_skips_when_in_sync(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    c = _client()
    # Pretend Jellyfin already returns the desired state (this can happen
    # after a manual paste then re-apply).
    desired = seed.desired_branding(s, current={})
    c.get_branding.return_value = dict(desired)
    state = _empty_state()
    seed.reconcile_branding(c, s, state)
    c.update_branding.assert_not_called()
    # Hash should still be recorded so subsequent runs don't re-GET.
    assert "branding" in state["sections"]


def test_reconcile_branding_writes_when_different(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    c = _client()
    c.get_branding.return_value = {"LoginDisclaimer": "old"}
    state = _empty_state()
    seed.reconcile_branding(c, s, state)
    c.update_branding.assert_called_once()
    args, _ = c.update_branding.call_args
    body = args[0]
    assert "LoginDisclaimer" in body
    assert "/sso/OID/start/zitadel" in body["LoginDisclaimer"]


def test_reconcile_branding_steady_state_skips(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    c = _client()
    c.get_branding.return_value = {"LoginDisclaimer": "old"}
    state = _empty_state()
    seed.reconcile_branding(c, s, state)
    c.update_branding.reset_mock()
    c.get_branding.reset_mock()
    # Second run: get_branding still returns old (stale), but the hash
    # cache has the desired hash → skip.
    c.get_branding.return_value = {"LoginDisclaimer": "old"}
    seed.reconcile_branding(c, s, state)
    c.update_branding.assert_not_called()


# --- sso_set_provider retry-on-404 (plugin-load race) ---------------------

def test_sso_set_provider_retries_on_404(monkeypatch: pytest.MonkeyPatch) -> None:
    """Plugin endpoints can 404 briefly during Jellyfin startup; the
    POST helper retries before giving up."""
    client = seed.JellyfinClient("http://j")
    client.token = "tok"
    calls = {"n": 0}

    def fake_request(method: str, path: str, **kwargs: Any) -> None:
        calls["n"] += 1
        if calls["n"] < 3:
            raise seed.JellyfinError(f"{method} {path} -> HTTP 404 Not Found: ''")
        return None

    monkeypatch.setattr(client, "_request", fake_request)
    monkeypatch.setattr(seed.time, "sleep", lambda _s: None)
    client.sso_set_provider("zitadel", {"OidEndpoint": "x"})
    assert calls["n"] == 3


def test_sso_set_provider_does_not_retry_on_401(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auth failures aren't a load race — surface immediately."""
    client = seed.JellyfinClient("http://j")
    client.token = "tok"
    calls = {"n": 0}

    def fake_request(method: str, path: str, **kwargs: Any) -> None:
        calls["n"] += 1
        raise seed.JellyfinError(f"{method} {path} -> HTTP 401 Unauthorized: ''")

    monkeypatch.setattr(client, "_request", fake_request)
    with pytest.raises(seed.JellyfinError, match="HTTP 401"):
        client.sso_set_provider("zitadel", {"OidEndpoint": "x"})
    assert calls["n"] == 1


# --- reconcile_users -------------------------------------------------------

def test_reconcile_users_creates_missing_and_skips_existing(tmp_path: Path) -> None:
    """jim is admin → SET password (Jellyfin 10.11+ requires it).
    tara is regular → RESET password (passwordless)."""
    s = _settings(tmp_path, users=["jim", "tara"], admin_users=["jim"])
    _write_secrets(tmp_path, admin_passwords={"jim": "jim-vault-pw"})
    c = _client()
    existing_policy = {
        "IsAdministrator": True,
        "IsHidden": False,
        "IsDisabled": False,
        "EnableAllFolders": True,
        "EnableUserPreferenceAccess": True,
    }
    c.list_users.return_value = [
        {"Name": "jim", "Id": PERSONAL_USER_ID},
    ]
    c.create_user.return_value = {"Name": "tara", "Id": PARTNER_USER_ID}
    c.get_user_policy.side_effect = [existing_policy, {}]

    seed.reconcile_users(c, s)

    c.create_user.assert_called_once_with("tara")
    # jim (admin) → set_user_password with the Vault-stored password.
    c.set_user_password.assert_called_once_with(PERSONAL_USER_ID, "jim-vault-pw")
    # tara (regular) → reset_user_password (passwordless).
    c.reset_user_password.assert_called_once_with(PARTNER_USER_ID)
    # jim policy already correct → no PATCH. tara had {} → PATCH.
    assert c.update_user_policy.call_count == 1
    args, _ = c.update_user_policy.call_args
    assert args[0] == PARTNER_USER_ID
    assert args[1]["IsAdministrator"] is False


def test_reconcile_users_admin_password_uses_per_user_secret(tmp_path: Path) -> None:
    """Each admin reads their own `password_<user>` from /mnt/secrets — no
    shared secret between admins or between an admin and the seed user."""
    s = _settings(tmp_path, users=["jim", "alice"], admin_users=["jim", "alice"])
    _write_secrets(tmp_path, admin_passwords={"jim": "jim-pw", "alice": "alice-pw"})
    c = _client()
    c.list_users.return_value = []
    c.create_user.side_effect = [
        {"Name": "jim", "Id": PERSONAL_USER_ID},
        {"Name": "alice", "Id": "alice-uuid"},
    ]
    c.get_user_policy.return_value = {}

    seed.reconcile_users(c, s)

    pw_calls = c.set_user_password.call_args_list
    assert (PERSONAL_USER_ID, "jim-pw") in [tuple(call.args) for call in pw_calls]
    assert ("alice-uuid", "alice-pw") in [tuple(call.args) for call in pw_calls]


def test_reconcile_users_promotes_existing_to_admin(tmp_path: Path) -> None:
    """A previously-non-admin user being promoted: policy update must
    happen BEFORE the password set so set_user_password lands on an
    already-admin record (Jellyfin's empty-password constraint is
    keyed on the user's CURRENT IsAdministrator state)."""
    s = _settings(tmp_path, users=["jim", "tara"], admin_users=["jim"])
    _write_secrets(tmp_path)
    c = _client()
    c.list_users.return_value = [
        {"Name": "jim", "Id": PERSONAL_USER_ID},
        {"Name": "tara", "Id": PARTNER_USER_ID},
    ]
    c.get_user_policy.side_effect = [
        {"IsAdministrator": False},  # jim — drift
        {"IsAdministrator": False, "IsHidden": False, "IsDisabled": False,
         "EnableAllFolders": True, "EnableUserPreferenceAccess": True},  # tara — correct
    ]
    parent = MagicMock()
    parent.attach_mock(c.update_user_policy, "update_user_policy")
    parent.attach_mock(c.set_user_password, "set_user_password")

    seed.reconcile_users(c, s)

    c.create_user.assert_not_called()
    # Only jim should be re-PATCHed.
    assert c.update_user_policy.call_count == 1
    args, _ = c.update_user_policy.call_args
    assert args[0] == PERSONAL_USER_ID
    assert args[1]["IsAdministrator"] is True
    # Order: policy update for jim must precede set_user_password for jim.
    method_order = [name for name, _, _ in parent.mock_calls]
    assert method_order.index("update_user_policy") < method_order.index("set_user_password")


def test_reconcile_startup_calls_get_before_post_user(tmp_path: Path) -> None:
    """Regression: POST /Startup/User 500s with `Sequence contains no
    elements` if GET /Startup/User hasn't run first — the GET handler
    calls _userManager.InitializeAsync() which creates the default
    user. The seed script must hit GET before POST."""
    s = _settings(tmp_path)
    _write_secrets(tmp_path)
    c = _client()
    c.is_in_startup_wizard.return_value = True

    # Track call ordering across the JellyfinClient methods we expect
    # the wizard walker to hit.
    parent = MagicMock()
    parent.attach_mock(c.startup_set_configuration, "set_configuration")
    parent.attach_mock(c.startup_initialize_user, "initialize_user")
    parent.attach_mock(c.startup_create_admin, "create_admin")
    parent.attach_mock(c.startup_set_remote_access, "set_remote_access")
    parent.attach_mock(c.startup_complete, "complete")

    seed.reconcile_startup(c, s)

    method_order = [name for name, _, _ in parent.mock_calls]
    # initialize_user (GET) must precede create_admin (POST).
    assert method_order.index("initialize_user") < method_order.index("create_admin"), \
        f"GET /Startup/User must run before POST /Startup/User; got order {method_order}"


def test_reconcile_users_skips_seed_user(tmp_path: Path) -> None:
    s = _settings(tmp_path, users=["_seed", "jim"], admin_users=["jim"])
    _write_secrets(tmp_path)
    c = _client()
    c.list_users.return_value = [{"Name": "_seed", "Id": SEED_USER_ID}]
    c.get_user_policy.return_value = {}
    c.create_user.return_value = {"Name": "jim", "Id": PERSONAL_USER_ID}

    seed.reconcile_users(c, s)

    # Only jim should be created — _seed is intentionally excluded.
    c.create_user.assert_called_once_with("jim")


# --- read_secret ----------------------------------------------------------

def test_read_secret_missing_raises(tmp_path: Path) -> None:
    with pytest.raises(seed.JellyfinError, match="missing secret"):
        seed.read_secret(tmp_path, "no_such_secret")


def test_read_secret_strips_trailing_newline(tmp_path: Path) -> None:
    (tmp_path / "x").write_text("value\n")
    assert seed.read_secret(tmp_path, "x") == "value"


# --- transient-error matcher ----------------------------------------------

@pytest.mark.parametrize("errno_val", [111, 104, 110, 113, -2, -3])
def test_transient_network_error_matches_known_errnos(errno_val: int) -> None:
    err = OSError(errno_val, "boom")
    exc = urllib.error.URLError(err)
    assert seed._is_transient_network_error(exc)


def test_transient_network_error_matches_timeouterror() -> None:
    exc = urllib.error.URLError(TimeoutError("timed out"))
    assert seed._is_transient_network_error(exc)


def test_transient_network_error_does_not_match_random_oserror() -> None:
    exc = urllib.error.URLError(OSError(99, "weird"))
    # str(reason).lower() may also catch some shapes — check the specific
    # errno-99 case isn't a false positive.
    assert not seed._is_transient_network_error(exc)


# --- Settings.from_env ----------------------------------------------------

def test_settings_from_env_happy_path(monkeypatch: pytest.MonkeyPatch,
                                       tmp_path: Path) -> None:
    monkeypatch.setenv("JELLYFIN_URL", "http://j:8096")
    monkeypatch.setenv("JELLYFIN_PUBLIC_URL", "https://j.example")
    monkeypatch.setenv("USERS", "jim,tara")
    monkeypatch.setenv("ADMIN_USERS", "jim")
    monkeypatch.setenv("OIDC_ISSUER_URL", ISSUER)
    monkeypatch.setenv("SECRETS_DIR", str(tmp_path))
    monkeypatch.setenv("SEED_STATE_PATH", str(tmp_path / "s.json"))

    s = seed.Settings.from_env()
    assert s.users == ["jim", "tara"]
    assert s.admin_users == ["jim"]
    assert s.oidc_issuer_url == ISSUER
    assert s.seed_user == "_seed"
    assert s.oidc_provider == "zitadel"


def test_settings_from_env_missing_users_aborts(monkeypatch: pytest.MonkeyPatch,
                                                  tmp_path: Path) -> None:
    monkeypatch.setenv("JELLYFIN_URL", "http://j:8096")
    monkeypatch.setenv("JELLYFIN_PUBLIC_URL", "https://j.example")
    monkeypatch.setenv("USERS", "")
    with pytest.raises(SystemExit):
        seed.Settings.from_env()
