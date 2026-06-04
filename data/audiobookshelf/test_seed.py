"""Tests for seed.py — focused on reconcile_oidc.

Covers:
  - empty OIDC_ISSUER_URL is a clean noop
  - missing /mnt/secrets/oidc_client_{id,secret} aborts with a clear error
  - happy path: full PATCH when ABS has no OIDC config yet
  - steady state: PATCH skipped when current == desired
  - partial drift: PATCH body contains only the diffed keys
  - email already matches OIDC_MATCH_EMAIL: no /api/users/<id> PATCH
  - email mismatch: /api/users/<id> PATCH then auth-settings PATCH
  - sensitive client_id/client_secret never appear in log output

Run with:

  uv run --exclude-newer '7 days' --with pytest pytest data/audiobookshelf/test_seed.py
"""
from __future__ import annotations

import io
import logging
import urllib.error
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

import seed


# --- helpers ---------------------------------------------------------------

CLIENT_ID = "client-id-abc"
CLIENT_SECRET = "client-secret-do-not-log"
ROOT_USER_ID = "root-user-uuid"
ISSUER = "https://oidc.example"

DISCOVERY = {
    "issuer": ISSUER,
    "authorization_endpoint": f"{ISSUER}/oauth/v2/authorize",
    "token_endpoint": f"{ISSUER}/oauth/v2/token",
    "userinfo_endpoint": f"{ISSUER}/oidc/v1/userinfo",
    "jwks_uri": f"{ISSUER}/oauth/v2/keys",
    "end_session_endpoint": f"{ISSUER}/oidc/v1/end_session",
    "id_token_signing_alg_values_supported": ["RS256"],
}

DESIRED_NEW = {
    "authOpenIDIssuerURL":             ISSUER,
    "authOpenIDAuthorizationURL":      DISCOVERY["authorization_endpoint"],
    "authOpenIDTokenURL":              DISCOVERY["token_endpoint"],
    "authOpenIDUserInfoURL":           DISCOVERY["userinfo_endpoint"],
    "authOpenIDJwksURL":               DISCOVERY["jwks_uri"],
    "authOpenIDLogoutURL":             DISCOVERY["end_session_endpoint"],
    "authOpenIDClientID":              CLIENT_ID,
    "authOpenIDClientSecret":          CLIENT_SECRET,
    "authOpenIDTokenSigningAlgorithm": "RS256",
    "authOpenIDButtonText":            "Login with Zitadel",
    "authOpenIDAutoLaunch":            True,
    "authOpenIDAutoRegister":          False,
    "authOpenIDMatchExistingBy":       "email",
    "authOpenIDMobileRedirectURIs":    ["audiobookshelf://oauth", "shelfplayer://callback"],
    "authOpenIDSubfolderForRedirectURLs": "",
    "authActiveAuthMethods":           ["local", "openid"],
}


def _settings(tmp_path: Path, **overrides: Any) -> seed.Settings:
    base = dict(
        abs_url="http://abs",
        users=["jim"],
        root_user="jim",
        secrets_dir=tmp_path,
        opml_path=tmp_path / "podcasts.opml",
        podcasts_dir="/podcasts",
        default_max_episodes=0,
        default_schedule="0 */6 * * *",
        auto_download_podcasts={},
        settings_wait_seconds=300,
        initial_lookback_days=7,
        fresh_import_window_seconds=21600,
        mark_finished_percent=None,
        oidc_issuer_url=ISSUER,
        oidc_match_email="jim@example.com",
        oidc_button_text="Login with Zitadel",
        oidc_mobile_redirect_uris=["audiobookshelf://oauth", "shelfplayer://callback"],
        seed_state_path=tmp_path / ".seed-state.json",
    )
    base.update(overrides)
    return seed.Settings(**base)


def _empty_state() -> dict:
    return {"version": seed.STATE_VERSION, "sections": {}}


def _write_oidc_secrets(secrets_dir: Path,
                        client_id: str = CLIENT_ID,
                        client_secret: str = CLIENT_SECRET) -> None:
    (secrets_dir / "oidc_client_id").write_text(client_id)
    (secrets_dir / "oidc_client_secret").write_text(client_secret)


def _client(current_auth: dict | None = None) -> MagicMock:
    """MagicMock spec'd to AbsClient with sensible default returns."""
    c = MagicMock(spec=seed.AbsClient)
    c.discover_oidc_config.return_value = dict(DISCOVERY)
    c.get_auth_settings.return_value = dict(current_auth or {})
    return c


def _root(email: str = "jim@example.com") -> dict:
    """Login-response shaped root user dict."""
    return {"id": ROOT_USER_ID, "email": email, "type": "root"}


# --- empty OIDC_ISSUER_URL -------------------------------------------------

def test_empty_issuer_is_noop(tmp_path: Path) -> None:
    s = _settings(tmp_path, oidc_issuer_url="")
    c = _client()
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    c.discover_oidc_config.assert_not_called()
    c.get_auth_settings.assert_not_called()
    c.update_auth_settings.assert_not_called()
    c.update_user_email.assert_not_called()


# --- missing CSI files -----------------------------------------------------

def test_missing_oidc_creds_raises(tmp_path: Path) -> None:
    s = _settings(tmp_path)
    c = _client()
    with pytest.raises(seed.AbsError, match="OIDC creds missing"):
        seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())
    c.update_auth_settings.assert_not_called()


# --- happy path: empty current settings, all keys land in PATCH -----------

def test_full_patch_when_abs_has_no_oidc_config(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth={})
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    c.update_user_email.assert_not_called()  # email already matches
    c.discover_oidc_config.assert_called_once_with(ISSUER)
    c.get_auth_settings.assert_called_once_with()
    c.update_auth_settings.assert_called_once()
    body = c.update_auth_settings.call_args.args[0]
    assert body == DESIRED_NEW


# --- steady state: no PATCH when current already matches desired ----------

def test_steady_state_no_patch(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth=dict(DESIRED_NEW))
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    c.update_auth_settings.assert_not_called()


# --- partial drift: only the diffed keys go in the PATCH body -------------

def test_partial_drift_patches_only_diff(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    # ABS has everything right except a stale client_secret + button text.
    current = dict(DESIRED_NEW)
    current["authOpenIDClientSecret"] = "stale-secret"
    current["authOpenIDButtonText"] = "Login with OpenId"
    c = _client(current_auth=current)
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    c.update_auth_settings.assert_called_once()
    body = c.update_auth_settings.call_args.args[0]
    assert set(body.keys()) == {"authOpenIDClientSecret", "authOpenIDButtonText"}
    assert body["authOpenIDClientSecret"] == CLIENT_SECRET
    assert body["authOpenIDButtonText"] == "Login with Zitadel"


# --- email already matches → skip user PATCH ------------------------------

def test_email_already_matches_skips_user_patch(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth=dict(DESIRED_NEW))
    seed.reconcile_oidc(c, s, root_user=_root(email="jim@example.com"), state=_empty_state())

    c.update_user_email.assert_not_called()


# --- email mismatch → PATCH user, then PATCH settings ---------------------

def test_email_mismatch_patches_user(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth={})
    seed.reconcile_oidc(c, s, root_user=_root(email=""), state=_empty_state())

    c.update_user_email.assert_called_once_with(ROOT_USER_ID, "jim@example.com")
    c.update_auth_settings.assert_called_once()


def test_email_missing_key_patches_user(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth={})
    # Defensive: some ABS builds may omit `email` from /login response.
    seed.reconcile_oidc(c, s, root_user={"id": ROOT_USER_ID, "type": "root"}, state=_empty_state())

    c.update_user_email.assert_called_once_with(ROOT_USER_ID, "jim@example.com")


def test_empty_match_email_skips_user_lookup(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path, oidc_match_email="")
    c = _client(current_auth={})
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    c.update_user_email.assert_not_called()
    c.update_auth_settings.assert_called_once()


# --- secrets must never appear in log output ------------------------------

def test_secrets_redacted_from_logs(tmp_path: Path,
                                    caplog: pytest.LogCaptureFixture) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth={})
    with caplog.at_level(logging.DEBUG, logger="seed"):
        seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    full_log = "\n".join(rec.getMessage() for rec in caplog.records)
    assert CLIENT_SECRET not in full_log
    assert CLIENT_ID not in full_log


# --- discovery doc shape sanity -------------------------------------------

# --- transient network retry: AbsClient._request behavior ----------------

def _conn_refused_urlerror() -> urllib.error.URLError:
    return urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))


def test_request_retries_on_connection_refused(monkeypatch: pytest.MonkeyPatch) -> None:
    """First two attempts hit ECONNREFUSED (Reloader bouncing the deployment),
    third succeeds. _request should backoff and ultimately return the body."""
    sleeps: list[float] = []
    monkeypatch.setattr(seed.time, "sleep", lambda s: sleeps.append(s))

    class _Resp:
        status = 200
        headers = {"Content-Type": "application/json"}
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b'{"ok": true}'

    calls = {"n": 0}
    def fake_urlopen(req, timeout):  # noqa: ARG001
        calls["n"] += 1
        if calls["n"] <= 2:
            raise _conn_refused_urlerror()
        return _Resp()

    with patch.object(seed.urllib.request, "urlopen", side_effect=fake_urlopen):
        client = seed.AbsClient("http://abs")
        result = client._request("GET", "/status")

    assert result == {"ok": True}
    assert calls["n"] == 3
    assert len(sleeps) == 2
    assert sleeps == [1.0, 2.0]  # exponential backoff base=1.0


def test_request_does_not_retry_on_http_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """4xx/5xx are responses, not transport faults — never retried."""
    sleeps: list[float] = []
    monkeypatch.setattr(seed.time, "sleep", lambda s: sleeps.append(s))

    def fake_urlopen(req, timeout):  # noqa: ARG001
        raise urllib.error.HTTPError(
            url="http://abs/x", code=401, msg="Unauthorized",
            hdrs=None, fp=io.BytesIO(b'{"error":"no"}'),
        )

    with patch.object(seed.urllib.request, "urlopen", side_effect=fake_urlopen):
        client = seed.AbsClient("http://abs")
        with pytest.raises(seed.AbsError, match="HTTP 401"):
            client._request("GET", "/api/users")

    assert sleeps == []  # no retry


def test_is_transient_network_error_classifies_correctly() -> None:
    f = seed._is_transient_network_error
    assert f(urllib.error.URLError(ConnectionRefusedError(111, "x")))
    assert f(urllib.error.URLError(ConnectionResetError(104, "x")))
    assert f(urllib.error.URLError(TimeoutError("timed out")))
    assert f(urllib.error.URLError(OSError(110, "ETIMEDOUT")))
    # Permanent: unsupported scheme is a programmer error, not transient.
    assert not f(urllib.error.URLError("unknown url type: ftp"))


# --- per-section hash cache -----------------------------------------------

def test_state_helpers_roundtrip(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    state = _empty_state()
    seed.record_section(state, "oidc", "abc")
    seed.save_seed_state(path, state)

    loaded = seed.load_seed_state(path)
    assert loaded["sections"]["oidc"]["hash"] == "abc"
    assert seed.section_cached(loaded, "oidc", "abc")
    assert not seed.section_cached(loaded, "oidc", "different")
    assert not seed.section_cached(loaded, "opml", "abc")


def test_load_seed_state_handles_missing_and_corrupt(tmp_path: Path) -> None:
    # Missing file -> empty.
    assert seed.load_seed_state(tmp_path / "missing.json")["sections"] == {}
    # Empty path -> empty (caching disabled).
    assert seed.load_seed_state(Path(""))["sections"] == {}
    # Corrupt -> empty (warning logged, run continues).
    bad = tmp_path / "bad.json"
    bad.write_text("not json {{{")
    assert seed.load_seed_state(bad)["sections"] == {}


def test_save_seed_state_noop_for_empty_path(tmp_path: Path) -> None:
    # When SEED_STATE_PATH is unset, save is a no-op (no exceptions).
    seed.save_seed_state(Path(""), _empty_state())


def test_save_seed_state_atomic(tmp_path: Path) -> None:
    """The .tmp sibling shouldn't linger after a successful write."""
    path = tmp_path / "state.json"
    seed.save_seed_state(path, _empty_state())
    assert path.is_file()
    assert not path.with_suffix(path.suffix + ".tmp").exists()


def test_section_hash_stable_for_dict_order() -> None:
    a = seed.section_hash({"x": 1, "y": 2}, ["a", "b"])
    b = seed.section_hash({"y": 2, "x": 1}, ["a", "b"])
    assert a == b
    different = seed.section_hash({"x": 1, "y": 3}, ["a", "b"])
    assert a != different


# --- reconcile_oidc cache gate --------------------------------------------

def test_reconcile_oidc_skips_when_hash_matches(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    c = _client(current_auth={})
    state = _empty_state()
    # First run: full work + state record.
    seed.reconcile_oidc(c, s, root_user=_root(), state=state)
    assert "oidc" in state["sections"]

    # Second run with same state: zero API calls.
    c2 = _client(current_auth={})
    seed.reconcile_oidc(c2, s, root_user=_root(), state=state)
    c2.discover_oidc_config.assert_not_called()
    c2.get_auth_settings.assert_not_called()
    c2.update_auth_settings.assert_not_called()
    c2.update_user_email.assert_not_called()


def test_reconcile_oidc_runs_when_hash_changes(tmp_path: Path) -> None:
    """A different client_secret on disk yields a different hash → re-run."""
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    state = _empty_state()
    seed.reconcile_oidc(_client(current_auth=dict(DESIRED_NEW)),
                        s, root_user=_root(), state=state)
    cached_hash = state["sections"]["oidc"]["hash"]

    # Rotate the client_secret on disk (simulating Zitadel rotation).
    _write_oidc_secrets(tmp_path, client_secret="rotated-secret")
    c = _client(current_auth=dict(DESIRED_NEW))  # ABS still has old value
    seed.reconcile_oidc(c, s, root_user=_root(), state=state)

    c.discover_oidc_config.assert_called_once()
    c.update_auth_settings.assert_called_once()
    body = c.update_auth_settings.call_args.args[0]
    assert body == {"authOpenIDClientSecret": "rotated-secret"}
    # State updated with new hash.
    assert state["sections"]["oidc"]["hash"] != cached_hash


def test_reconcile_oidc_persists_state_on_diff_empty_path(tmp_path: Path) -> None:
    """Even when the diff is empty (ABS already in sync), record the new
    hash so the next run skips entirely."""
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    state = _empty_state()
    c = _client(current_auth=dict(DESIRED_NEW))
    seed.reconcile_oidc(c, s, root_user=_root(), state=state)

    c.update_auth_settings.assert_not_called()
    assert "oidc" in state["sections"]
    # State written to disk.
    assert s.seed_state_path.is_file()


def test_missing_logout_url_defaults_to_empty(tmp_path: Path) -> None:
    _write_oidc_secrets(tmp_path)
    s = _settings(tmp_path)
    discovery = dict(DISCOVERY)
    del discovery["end_session_endpoint"]
    c = _client(current_auth={})
    c.discover_oidc_config.return_value = discovery
    seed.reconcile_oidc(c, s, root_user=_root(), state=_empty_state())

    body = c.update_auth_settings.call_args.args[0]
    assert body["authOpenIDLogoutURL"] == ""


# --- desired_media_payload: auto-download default + opt-out ---------------

def _item(feed_url: str, item_id: str = "item-1", added_at_ms: int = 0) -> dict:
    return {
        "id": item_id,
        "addedAt": added_at_ms,
        "media": {"metadata": {"feedUrl": feed_url}},
    }


def test_unlisted_feed_defaults_to_auto_download_on(tmp_path: Path) -> None:
    s = _settings(tmp_path, default_max_episodes=3, default_schedule="0 */4 * * *")
    payload = seed.desired_media_payload("https://feeds.npr.org/up-first", s, _item("https://feeds.npr.org/up-first"))
    assert payload["autoDownloadEpisodes"] is True
    assert payload["autoDownloadSchedule"] == "0 */4 * * *"
    assert payload["maxEpisodesToKeep"] == 3


def test_override_can_opt_out_of_auto_download(tmp_path: Path) -> None:
    s = _settings(
        tmp_path,
        default_max_episodes=3,
        auto_download_podcasts={"https://feeds.npr.org/up-first": {"auto_download": False}},
    )
    payload = seed.desired_media_payload("https://feeds.npr.org/up-first", s, _item("https://feeds.npr.org/up-first"))
    assert payload["autoDownloadEpisodes"] is False
    # ABS expects maxEpisodesToKeep regardless; schedule is omitted when off.
    assert "autoDownloadSchedule" not in payload
    assert payload["maxEpisodesToKeep"] == 3


def test_override_schedule_and_max_apply(tmp_path: Path) -> None:
    s = _settings(
        tmp_path,
        default_max_episodes=3,
        default_schedule="0 */4 * * *",
        auto_download_podcasts={
            "https://feeds.example/foo": {"schedule": "0 0 * * *", "max_episodes_to_keep": 10},
        },
    )
    payload = seed.desired_media_payload("https://feeds.example/foo", s, _item("https://feeds.example/foo"))
    assert payload["autoDownloadEpisodes"] is True
    assert payload["autoDownloadSchedule"] == "0 0 * * *"
    assert payload["maxEpisodesToKeep"] == 10


def test_url_normalization_matches_override(tmp_path: Path) -> None:
    # OPML and override key differ in trailing slash + scheme; norm_url should match.
    s = _settings(
        tmp_path,
        auto_download_podcasts={"http://feeds.example/foo/": {"auto_download": False}},
    )
    payload = seed.desired_media_payload("https://feeds.example/foo", s, _item("https://feeds.example/foo"))
    assert payload["autoDownloadEpisodes"] is False


# --- reconcile_library_settings -------------------------------------------

def test_library_settings_patched_when_pct_diverges(tmp_path: Path) -> None:
    s = _settings(tmp_path, mark_finished_percent=94.0)
    c = _client()
    c.list_libraries.return_value = [{
        "id": "lib-1", "mediaType": "podcast",
        "settings": {"markAsFinishedPercentComplete": None},
    }]

    seed.reconcile_library_settings(c, s, library_id="lib-1", state=_empty_state())

    c.update_library.assert_called_once_with("lib-1", {"settings": {"markAsFinishedPercentComplete": 94.0}})


def test_library_settings_skips_when_already_set(tmp_path: Path) -> None:
    s = _settings(tmp_path, mark_finished_percent=94.0)
    c = _client()
    c.list_libraries.return_value = [{
        "id": "lib-1", "mediaType": "podcast",
        "settings": {"markAsFinishedPercentComplete": 94.0},
    }]

    seed.reconcile_library_settings(c, s, library_id="lib-1", state=_empty_state())

    c.update_library.assert_not_called()


def test_library_settings_noop_when_unset(tmp_path: Path) -> None:
    # mark_finished_percent=None → desired==None; if ABS already has null, no PATCH.
    s = _settings(tmp_path, mark_finished_percent=None)
    c = _client()
    c.list_libraries.return_value = [{
        "id": "lib-1", "mediaType": "podcast",
        "settings": {"markAsFinishedPercentComplete": None},
    }]

    seed.reconcile_library_settings(c, s, library_id="lib-1", state=_empty_state())

    c.update_library.assert_not_called()


def test_library_settings_clears_when_unset_but_currently_set(tmp_path: Path) -> None:
    # User removes the var → seed must reset ABS back to null so the
    # time-remaining setting takes over again.
    s = _settings(tmp_path, mark_finished_percent=None)
    c = _client()
    c.list_libraries.return_value = [{
        "id": "lib-1", "mediaType": "podcast",
        "settings": {"markAsFinishedPercentComplete": 94.0},
    }]

    seed.reconcile_library_settings(c, s, library_id="lib-1", state=_empty_state())

    c.update_library.assert_called_once_with("lib-1", {"settings": {"markAsFinishedPercentComplete": None}})


def test_library_settings_hash_cached(tmp_path: Path) -> None:
    s = _settings(tmp_path, mark_finished_percent=94.0)
    c = _client()
    c.list_libraries.return_value = [{
        "id": "lib-1", "mediaType": "podcast",
        "settings": {"markAsFinishedPercentComplete": None},
    }]

    state = _empty_state()
    seed.reconcile_library_settings(c, s, library_id="lib-1", state=state)
    # First call PATCHed; second call hits the hash cache and skips entirely.
    c.update_library.reset_mock()
    c.list_libraries.reset_mock()
    seed.reconcile_library_settings(c, s, library_id="lib-1", state=state)

    c.update_library.assert_not_called()
    c.list_libraries.assert_not_called()


# --- _parse_optional_float ------------------------------------------------

def test_parse_optional_float_blank_is_none() -> None:
    assert seed._parse_optional_float("") is None
    assert seed._parse_optional_float("   ") is None
    assert seed._parse_optional_float(None) is None  # type: ignore[arg-type]


def test_parse_optional_float_value() -> None:
    assert seed._parse_optional_float("94") == 94.0
    assert seed._parse_optional_float("0.5") == 0.5


def test_parse_optional_float_bad_dies() -> None:
    with pytest.raises(SystemExit):
        seed._parse_optional_float("not-a-number")
