"""Tests for get-zitadel-token.py.

Critical contracts:
  - PKCE: code_verifier ↔ S256 challenge round-trip per RFC 7636
  - token endpoint POST uses HTTP Basic auth from client_id/secret
  - `expires_at` is stamped as absolute unix ts on save
  - `token` subcommand refreshes when within REFRESH_LEEWAY of expiry
  - `token` subcommand prints JUST the access_token to stdout (so shell
    wrappers can do `Authorization: Bearer $(… token)` cleanly)
  - state-mismatch in callback aborts without writing tokens
  - missing required env vars exit 2 with a clear message
  - secrets (client_secret, refresh_token) never appear in stdout
  - backend cascade: auto picks first available, explicit forces a tier,
    file backend always wins as last resort
  - file backend writes mode 0600 and lands under XDG_STATE_HOME by default
  - secret-tool backend invokes the CLI with the correct attributes
  - per-app namespacing: keyring attrs include account=<client_id>

Backends specific to Linux Secret Service (gi-secret / secretstorage /
dbus-python) are exercised via test doubles installed into sys.modules —
the test host doesn't need libsecret, PyGObject, secretstorage, or
dbus-python actually installed.

Run with:

  uv run --with pytest pytest data/scripts/test_get_zitadel_token.py
"""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock, patch

import pytest


def _load_module() -> Any:
    here = Path(__file__).parent
    spec = importlib.util.spec_from_file_location(
        "get_zitadel_token", here / "get-zitadel-token.py"
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gz = _load_module()


CLIENT_ID = "opencode-client-id"
CLIENT_SECRET = "do-not-leak-this-secret"
REFRESH_TOKEN = "do-not-leak-this-refresh-token"


# --- shared fixtures -------------------------------------------------------

@pytest.fixture
def file_backend(tmp_path: Path) -> Any:
    return gz._FileBackend(tmp_path / "tokens.json")


@pytest.fixture
def cfg_file(tmp_path: Path) -> dict:
    return {
        "app_name":      "opencode",
        "issuer":        "https://oidc.example",
        "client_id":     CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "backend":       gz._FileBackend(tmp_path / "tokens.json"),
        "tokens_path":   tmp_path / "tokens.json",
        "keyring_label": "Zitadel OIDC tokens (opencode)",
        "redirect_port": 9876,
        "scopes":        "openid email profile offline_access",
        "leeway":        60,
        "cached":        {},
    }


def _seed_cache(cfg: dict, tokens: dict) -> None:
    """Populate cfg["cached"] with config + the given token fields, matching
    what _save would persist. Use in tests that exercise refresh/token
    flows without going through cmd_login."""
    cfg["cached"] = {
        "issuer":        cfg["issuer"],
        "client_id":     cfg["client_id"],
        "client_secret": cfg["client_secret"],
        **tokens,
    }


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # APP_NAME + the three OIDC env vars are read as argparse defaults at
    # parser-construction time, so tests don't need to pass --app/--issuer
    # to exercise common paths.
    monkeypatch.setenv("APP_NAME", "opencode")
    monkeypatch.setenv("ZITADEL_ISSUER", "https://oidc.example")
    monkeypatch.setenv("ZITADEL_CLIENT_ID", CLIENT_ID)
    monkeypatch.setenv("ZITADEL_CLIENT_SECRET", CLIENT_SECRET)
    monkeypatch.setenv("TOKENS_PATH", str(tmp_path / "tokens.json"))
    monkeypatch.setenv("STORAGE_BACKEND", "file")  # don't probe real DBus


def _parse(*argv: str) -> Any:
    """Convenience: build the real parser and parse `argv` (no extra
    args beyond what's passed). Tests use this to construct a Namespace
    that matches what `main()` would feed `_cfg`."""
    return gz._build_parser().parse_args(list(argv))


# --- _cfg ------------------------------------------------------------------

def test_cfg_reads_env(tmp_path: Path) -> None:
    c = gz._cfg(_parse("status"))
    assert c["issuer"] == "https://oidc.example"
    assert c["client_id"] == CLIENT_ID
    assert c["client_secret"] == CLIENT_SECRET
    assert c["tokens_path"] == tmp_path / "tokens.json"
    assert c["backend"].name == "file"
    assert c["app_name"] == "opencode"
    assert c["cached"] == {}  # empty on first run


def test_cfg_loads_cached_config(monkeypatch: pytest.MonkeyPatch,
                                 tmp_path: Path) -> None:
    """If a cached blob exists, _cfg fills missing CLI/env from it — the
    whole point of the persistence layer."""
    cached = {
        "issuer":        "https://oidc.example",
        "client_id":     CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "access_token":  "stashed-jwt",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    9_999_999_999,
    }
    (tmp_path / "tokens.json").write_bytes(json.dumps(cached).encode())

    for v in ("ZITADEL_ISSUER", "ZITADEL_CLIENT_ID", "ZITADEL_CLIENT_SECRET"):
        monkeypatch.delenv(v)

    c = gz._cfg(_parse("status"))
    assert c["issuer"] == "https://oidc.example"
    assert c["client_id"] == CLIENT_ID
    assert c["client_secret"] == CLIENT_SECRET
    assert c["cached"]["access_token"] == "stashed-jwt"


def test_cfg_env_overrides_cache(monkeypatch: pytest.MonkeyPatch,
                                 tmp_path: Path) -> None:
    """Env wins over cache — useful for rotating client_secret."""
    (tmp_path / "tokens.json").write_bytes(json.dumps({
        "issuer":        "https://stale.example",
        "client_id":     "stale-id",
        "client_secret": "stale-secret",
    }).encode())
    monkeypatch.delenv("ZITADEL_ISSUER")
    monkeypatch.delenv("ZITADEL_CLIENT_ID")
    monkeypatch.setenv("ZITADEL_CLIENT_SECRET", "rotated-secret")

    c = gz._cfg(_parse("status"))
    assert c["client_secret"] == "rotated-secret"
    assert c["issuer"] == "https://stale.example"
    assert c["client_id"] == "stale-id"


def test_cli_flag_overrides_env(monkeypatch: pytest.MonkeyPatch,
                                tmp_path: Path) -> None:
    """CLI flag beats env beats cache."""
    monkeypatch.setenv("ZITADEL_CLIENT_SECRET", "env-secret")
    c = gz._cfg(_parse("login", "--client-secret", "cli-secret"))
    assert c["client_secret"] == "cli-secret"


def test_cli_flag_app_overrides_env(monkeypatch: pytest.MonkeyPatch,
                                    tmp_path: Path) -> None:
    monkeypatch.setenv("APP_NAME", "from-env")
    c = gz._cfg(_parse("status", "--app", "from-cli"))
    assert c["app_name"] == "from-cli"


def test_cfg_no_app_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("APP_NAME")
    with pytest.raises(SystemExit) as e:
        gz._cfg(_parse("status"))
    assert "--app" in str(e.value) or "APP_NAME" in str(e.value)


def test_cfg_no_env_no_cache_leaves_blanks(monkeypatch: pytest.MonkeyPatch) -> None:
    """`_cfg` itself never errors on missing OIDC config — subcommands
    enforce via `_require_config`. This lets `status`/`logout` work
    without env when there's a cached blob."""
    for v in ("ZITADEL_ISSUER", "ZITADEL_CLIENT_ID", "ZITADEL_CLIENT_SECRET"):
        monkeypatch.delenv(v)
    c = gz._cfg(_parse("status"))
    assert c["issuer"] == ""
    assert c["client_id"] == ""
    assert c["client_secret"] == ""


def test_require_config_lists_missing(cfg_file: dict) -> None:
    cfg_file["client_id"] = ""
    cfg_file["client_secret"] = ""
    with pytest.raises(SystemExit) as e:
        gz._require_config(cfg_file)
    msg = str(e.value)
    assert "--client-id" in msg or "ZITADEL_CLIENT_ID" in msg
    assert "--client-secret" in msg or "ZITADEL_CLIENT_SECRET" in msg


def test_cfg_trims_trailing_slash(monkeypatch: pytest.MonkeyPatch) -> None:
    c = gz._cfg(_parse("status", "--issuer", "https://oidc.example/"))
    assert c["issuer"] == "https://oidc.example"


def test_attrs_namespaces_by_app_name() -> None:
    assert gz._attrs("opencode") == {"service": "zitadel", "app": "opencode"}
    assert gz._attrs("custom") == {"service": "zitadel", "app": "custom"}


def test_default_tokens_path_uses_xdg_state_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    monkeypatch.delenv("TOKENS_PATH", raising=False)
    c = gz._cfg(_parse("status"))
    assert c["tokens_path"] == tmp_path / "zitadel" / "tokens.json"


def test_parser_rejects_missing_subcommand() -> None:
    with pytest.raises(SystemExit):
        gz._build_parser().parse_args([])


def test_parser_rejects_unknown_subcommand() -> None:
    with pytest.raises(SystemExit):
        gz._build_parser().parse_args(["nope"])


# --- backend selection (cascade) ------------------------------------------

class _StubBackend:
    """Tiny stand-in used to script which backends declare themselves
    available in cascade tests."""
    instances: list[Any] = []

    def __init__(self, name: str, available: bool) -> None:
        self.name = name
        self.available = available
        self.calls: list[tuple] = []
        _StubBackend.instances.append(self)


def _stub_chain(monkeypatch: pytest.MonkeyPatch,
                availability: list[bool]) -> list[type]:
    """Replace _BACKEND_CHAIN with stubs that report availability per spec."""
    names = ["gi-secret", "secretstorage", "dbus-python", "secret-tool", "file"]
    assert len(availability) == len(names)

    classes: list[type] = []
    for n, avail in zip(names, availability):
        def make(name: str, available: bool):
            class C:
                _name = name
                _available = available
                def __init__(self, _tokens_path: Any) -> None:
                    self.name = name
                    self.available = available
            C.name = name  # class attr too, for _BY_NAME map
            return C
        classes.append(make(n, avail))

    monkeypatch.setattr(gz, "_BACKEND_CHAIN", classes)
    monkeypatch.setattr(gz, "_BY_NAME", {c.name: c for c in classes})
    return classes


def test_auto_picks_first_available(monkeypatch: pytest.MonkeyPatch,
                                    tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "auto")
    _stub_chain(monkeypatch, [False, True, False, False, True])
    b = gz._pick_backend(tmp_path / "x")
    assert b.name == "secretstorage"


def test_auto_falls_through_to_file(monkeypatch: pytest.MonkeyPatch,
                                    tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "auto")
    _stub_chain(monkeypatch, [False, False, False, False, True])
    b = gz._pick_backend(tmp_path / "x")
    assert b.name == "file"


def test_auto_prefers_gi_secret_when_all_available(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "auto")
    _stub_chain(monkeypatch, [True, True, True, True, True])
    b = gz._pick_backend(tmp_path / "x")
    assert b.name == "gi-secret"


def test_explicit_backend_honored(monkeypatch: pytest.MonkeyPatch,
                                  tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "dbus-python")
    _stub_chain(monkeypatch, [True, True, True, True, True])
    b = gz._pick_backend(tmp_path / "x")
    assert b.name == "dbus-python"


def test_explicit_backend_unavailable_errors(monkeypatch: pytest.MonkeyPatch,
                                             tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "gi-secret")
    _stub_chain(monkeypatch, [False, True, True, True, True])
    with pytest.raises(SystemExit) as e:
        gz._pick_backend(tmp_path / "x")
    assert "gi-secret" in str(e.value)


def test_unknown_backend_errors(monkeypatch: pytest.MonkeyPatch,
                                tmp_path: Path) -> None:
    monkeypatch.setenv("STORAGE_BACKEND", "carrier-pigeon")
    with pytest.raises(SystemExit) as e:
        gz._pick_backend(tmp_path / "x")
    assert "carrier-pigeon" in str(e.value)


# --- PKCE round-trip -------------------------------------------------------

def test_b64url_no_padding() -> None:
    out = gz._b64url(b"\x00" * 32)
    assert "=" not in out
    assert "+" not in out and "/" not in out


def test_pkce_challenge_matches_verifier() -> None:
    import secrets as _s
    verifier = gz._b64url(_s.token_bytes(64))
    challenge = gz._b64url(hashlib.sha256(verifier.encode()).digest())
    pad = "=" * (-len(challenge) % 4)
    raw = base64.urlsafe_b64decode(challenge + pad)
    assert raw == hashlib.sha256(verifier.encode()).digest()


# --- _stamp ----------------------------------------------------------------

def test_stamp_sets_absolute_expires_at() -> None:
    with patch.object(gz.time, "time", return_value=1_000_000):
        out = gz._stamp({"expires_in": 3600})
    assert out["expires_at"] == 1_003_600


def test_stamp_defaults_expires_in_to_3600() -> None:
    with patch.object(gz.time, "time", return_value=2_000_000):
        out = gz._stamp({})
    assert out["expires_at"] == 2_003_600


# --- _post_token: HTTP Basic auth header construction ----------------------

def test_post_token_sends_basic_auth(cfg_file: dict) -> None:
    captured: dict = {}

    class FakeResp:
        def read(self) -> bytes:
            return b'{"access_token":"jwt","refresh_token":"rt","expires_in":3600}'
        def __enter__(self): return self
        def __exit__(self, *_a): return False

    def fake_urlopen(req: Any, **_kw: Any) -> FakeResp:
        captured["url"] = req.full_url
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        captured["body"] = req.data.decode()
        return FakeResp()

    with patch.object(gz.urllib.request, "urlopen", fake_urlopen):
        out = gz._post_token(cfg_file, {"grant_type": "refresh_token",
                                        "refresh_token": REFRESH_TOKEN})

    assert captured["url"] == "https://oidc.example/oauth/v2/token"
    expected = "Basic " + base64.b64encode(
        f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
    assert captured["headers"]["authorization"] == expected
    assert "grant_type=refresh_token" in captured["body"]
    assert out["access_token"] == "jwt"


# --- file backend ---------------------------------------------------------

def test_file_save_writes_0600(file_backend: Any) -> None:
    file_backend.save("lbl", {}, b'{"x":1}')
    mode = file_backend.path.stat().st_mode & 0o777
    assert mode == 0o600


def test_file_load_missing_returns_none(file_backend: Any) -> None:
    assert file_backend.load({}) is None


def test_file_roundtrip(file_backend: Any) -> None:
    file_backend.save("lbl", {}, b"hello")
    assert file_backend.load({}) == b"hello"


def test_file_clear_removes(file_backend: Any) -> None:
    file_backend.save("lbl", {}, b"x")
    file_backend.clear({})
    assert not file_backend.path.exists()


def test_file_clear_missing_is_noop(file_backend: Any) -> None:
    file_backend.clear({})  # must not raise


# --- secret-tool backend --------------------------------------------------

def _fake_run(rc: int = 0, stdout: bytes = b"", stderr: bytes = b""):
    """Return a fake subprocess.run that captures argv + records the result."""
    calls: list[dict] = []

    def run(argv: list[str], input: bytes | None = None,  # noqa: A002
            capture_output: bool = False) -> Any:
        calls.append({"argv": argv, "input": input})
        return SimpleNamespace(returncode=rc, stdout=stdout, stderr=stderr)
    return run, calls


def test_secret_tool_available_when_binary_present(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    assert b.available


def test_secret_tool_unavailable_when_binary_missing(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value=None):
        b = gz._SecretTool(tmp_path / "x")
    assert not b.available


def test_secret_tool_save_invokes_cli_with_attrs(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    run, calls = _fake_run(rc=0)
    with patch.object(gz.subprocess, "run", run):
        b.save("lbl", {"service": "zitadel", "account": CLIENT_ID}, b'{"x":1}')
    argv = calls[0]["argv"]
    assert argv[0:2] == ["secret-tool", "store"]
    assert "--label" in argv
    assert "service" in argv and "zitadel" in argv
    assert "account" in argv and CLIENT_ID in argv
    # Secret transits via stdin, never argv.
    assert calls[0]["input"] == b'{"x":1}'
    assert '{"x":1}' not in " ".join(argv)


def test_secret_tool_save_propagates_failure(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    run, _ = _fake_run(rc=1, stderr=b"locked")
    with patch.object(gz.subprocess, "run", run), \
         pytest.raises(RuntimeError, match="locked"):
        b.save("lbl", {}, b"x")


def test_secret_tool_load_strips_trailing_newline(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    payload = json.dumps({"k": "v"}).encode() + b"\n"
    run, _ = _fake_run(rc=0, stdout=payload)
    with patch.object(gz.subprocess, "run", run):
        out = b.load({})
    assert out == json.dumps({"k": "v"}).encode()


def test_secret_tool_load_empty_returns_none(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    run, _ = _fake_run(rc=1, stdout=b"")
    with patch.object(gz.subprocess, "run", run):
        assert b.load({}) is None


def test_secret_tool_clear_invokes_cli(tmp_path: Path) -> None:
    with patch.object(gz.shutil, "which", return_value="/usr/bin/secret-tool"):
        b = gz._SecretTool(tmp_path / "x")
    run, calls = _fake_run(rc=0)
    with patch.object(gz.subprocess, "run", run):
        b.clear({"service": "zitadel"})
    assert calls[0]["argv"][0:2] == ["secret-tool", "clear"]


# --- gi-secret backend (via stub `gi` and `gi.repository.Secret`) ---------

def _install_fake_gi(monkeypatch: pytest.MonkeyPatch,
                     fake_secret: Any) -> None:
    """Inject fakes for `gi`, `gi.repository`, and `gi.repository.Secret`
    so _GISecret.__init__ succeeds without PyGObject installed."""
    gi_mod = SimpleNamespace(require_version=lambda *_a, **_k: None,
                             repository=SimpleNamespace(Secret=fake_secret))
    monkeypatch.setitem(sys.modules, "gi", gi_mod)
    monkeypatch.setitem(sys.modules, "gi.repository", gi_mod.repository)


def test_gi_secret_save_calls_password_store(monkeypatch: pytest.MonkeyPatch,
                                             tmp_path: Path) -> None:
    calls: list[dict] = []

    class FakeSchema:
        pass

    class FakeSecret:
        SchemaFlags = SimpleNamespace(NONE=0)
        SchemaAttributeType = SimpleNamespace(STRING="STRING")
        COLLECTION_DEFAULT = "default"

        class Schema:
            @staticmethod
            def new(name: str, flags: int, attrs: dict) -> Any:
                return FakeSchema()

        @staticmethod
        def password_store_sync(schema: Any, attrs: dict, collection: str,
                                label: str, secret: str, _cancel: Any) -> bool:
            calls.append({"schema": schema, "attrs": dict(attrs),
                          "collection": collection, "label": label,
                          "secret": secret})
            return True

    _install_fake_gi(monkeypatch, FakeSecret)
    b = gz._GISecret(tmp_path / "x")
    assert b.available
    b.save("lbl", {"service": "zitadel", "account": CLIENT_ID}, b'{"k":"v"}')
    assert calls[0]["label"] == "lbl"
    assert calls[0]["attrs"] == {"service": "zitadel", "account": CLIENT_ID}
    assert calls[0]["secret"] == '{"k":"v"}'


def test_gi_secret_load_returns_bytes_or_none(monkeypatch: pytest.MonkeyPatch,
                                              tmp_path: Path) -> None:
    state = {"value": "stored-jwt"}

    class FakeSecret:
        SchemaFlags = SimpleNamespace(NONE=0)
        SchemaAttributeType = SimpleNamespace(STRING="STRING")
        COLLECTION_DEFAULT = "default"

        class Schema:
            @staticmethod
            def new(*_a, **_k): return object()

        @staticmethod
        def password_lookup_sync(*_a, **_k):
            return state["value"]

    _install_fake_gi(monkeypatch, FakeSecret)
    b = gz._GISecret(tmp_path / "x")
    assert b.load({}) == b"stored-jwt"

    state["value"] = None
    assert b.load({}) is None


def test_gi_secret_unavailable_when_pygobject_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    monkeypatch.setitem(sys.modules, "gi", None)  # import gi → ImportError
    b = gz._GISecret(tmp_path / "x")
    assert not b.available


# --- secretstorage backend (via stub) -------------------------------------

def _install_fake_secretstorage(monkeypatch: pytest.MonkeyPatch,
                                items: dict[tuple, bytes]) -> Any:
    """Provide a fake `secretstorage` module backed by an in-memory map."""

    class FakeItem:
        def __init__(self, attrs: dict, blob: bytes) -> None:
            self.attrs = attrs
            self.blob = blob
        def get_secret(self) -> bytes: return self.blob
        def delete(self) -> None:
            key = tuple(sorted(self.attrs.items()))
            items.pop(key, None)

    class FakeCollection:
        def is_locked(self) -> bool: return False
        def unlock(self) -> None: pass
        def search_items(self, attrs: dict) -> list[FakeItem]:
            return [FakeItem(dict(k), v) for k, v in items.items()
                    if dict(k).items() >= attrs.items()]
        def create_item(self, label: str, attrs: dict, blob: bytes,
                        replace: bool = True) -> None:
            items[tuple(sorted(attrs.items()))] = blob

    fake_mod = SimpleNamespace(
        dbus_init=lambda: object(),
        get_default_collection=lambda _conn: FakeCollection(),
    )
    monkeypatch.setitem(sys.modules, "secretstorage", fake_mod)
    return fake_mod


def test_secretstorage_save_and_load(monkeypatch: pytest.MonkeyPatch,
                                     tmp_path: Path) -> None:
    items: dict[tuple, bytes] = {}
    _install_fake_secretstorage(monkeypatch, items)
    b = gz._SecretStorage(tmp_path / "x")
    assert b.available
    attrs = {"service": "zitadel", "account": CLIENT_ID}
    b.save("lbl", attrs, b'{"jwt":1}')
    assert b.load(attrs) == b'{"jwt":1}'
    b.clear(attrs)
    assert b.load(attrs) is None


def test_secretstorage_unavailable_when_module_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    monkeypatch.setitem(sys.modules, "secretstorage", None)
    b = gz._SecretStorage(tmp_path / "x")
    assert not b.available


# --- dbus-python backend (via stub) ---------------------------------------

def test_dbus_python_unavailable_when_module_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    monkeypatch.setitem(sys.modules, "dbus", None)
    b = gz._DBusPython(tmp_path / "x")
    assert not b.available


def test_dbus_python_available_when_session_bus_reachable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    """The probe should succeed if `dbus` imports and SessionBus().get_object
    returns without raising. We don't exercise full save/load — those rely
    on a live Secret Service daemon and aren't a good unit target."""
    fake_bus = MagicMock()
    fake_bus.get_object.return_value = MagicMock()
    fake_dbus = SimpleNamespace(SessionBus=lambda: fake_bus)
    monkeypatch.setitem(sys.modules, "dbus", fake_dbus)
    b = gz._DBusPython(tmp_path / "x")
    assert b.available


# --- cmd_refresh / cmd_token (file backend) -------------------------------

def test_refresh_stamps_expiry_and_keeps_refresh_token(cfg_file: dict) -> None:
    _seed_cache(cfg_file, {
        "access_token":  "old-jwt",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    0,
    })
    fake_response = {
        "access_token":  "new-jwt",
        "expires_in":    1800,
        "token_type":    "Bearer",
    }
    with patch.object(gz, "_post_token", return_value=fake_response), \
         patch.object(gz.time, "time", return_value=5_000_000):
        out = gz.cmd_refresh(cfg_file)
    assert out["access_token"] == "new-jwt"
    assert out["refresh_token"] == REFRESH_TOKEN
    assert out["expires_at"] == 5_001_800
    # Cache still carries the config alongside the tokens.
    assert out["client_id"] == CLIENT_ID


def test_refresh_rotates_refresh_token_when_returned(cfg_file: dict) -> None:
    _seed_cache(cfg_file, {
        "access_token":  "old",
        "refresh_token": "old-rt",
        "expires_at":    0,
    })
    with patch.object(gz, "_post_token",
                      return_value={"access_token": "new", "refresh_token": "new-rt",
                                    "expires_in": 3600}), \
         patch.object(gz.time, "time", return_value=1_000):
        out = gz.cmd_refresh(cfg_file)
    assert out["refresh_token"] == "new-rt"


def test_refresh_aborts_when_no_refresh_token_cached(cfg_file: dict) -> None:
    _seed_cache(cfg_file, {"access_token": "x"})
    with pytest.raises(SystemExit):
        gz.cmd_refresh(cfg_file)


def test_refresh_aborts_when_config_missing(cfg_file: dict) -> None:
    cfg_file["client_secret"] = ""
    _seed_cache(cfg_file, {
        "access_token":  "x",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    9_999_999_999,
    })
    # Wipe client_secret from the cache too so _require_config has nothing
    # to fall back on (mirrors the env+cache being out of sync).
    cfg_file["cached"]["client_secret"] = ""
    cfg_file["client_secret"] = ""
    with pytest.raises(SystemExit) as e:
        gz.cmd_refresh(cfg_file)
    assert "ZITADEL_CLIENT_SECRET" in str(e.value)


def test_token_prints_only_access_token(cfg_file: dict,
                                        capsys: pytest.CaptureFixture) -> None:
    _seed_cache(cfg_file, {
        "access_token":  "the-jwt",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    9_999_999_999,
    })
    gz.cmd_token(cfg_file)
    out, _ = capsys.readouterr()
    assert out.strip() == "the-jwt"
    assert CLIENT_SECRET not in out
    assert REFRESH_TOKEN not in out


def test_token_auto_refreshes_when_within_leeway(
    cfg_file: dict, capsys: pytest.CaptureFixture,
) -> None:
    _seed_cache(cfg_file, {
        "access_token":  "stale-jwt",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    1_000_000 + 30,
    })
    refreshed = {"access_token": "fresh-jwt", "expires_in": 3600}
    with patch.object(gz, "_post_token", return_value=refreshed), \
         patch.object(gz.time, "time", return_value=1_000_000):
        gz.cmd_token(cfg_file)
    out, _ = capsys.readouterr()
    assert out.strip() == "fresh-jwt"


def test_token_does_not_refresh_when_well_in_future(cfg_file: dict) -> None:
    _seed_cache(cfg_file, {
        "access_token":  "still-good",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    9_999_999_999,
    })
    with patch.object(gz, "_post_token",
                      side_effect=AssertionError("should not refresh")):
        gz.cmd_token(cfg_file)


def test_status_works_without_env(cfg_file: dict,
                                  capsys: pytest.CaptureFixture) -> None:
    """The whole point of caching config: `status` runs cold without env."""
    _seed_cache(cfg_file, {
        "access_token":  "j",
        "refresh_token": REFRESH_TOKEN,
        "expires_at":    9_999_999_999,
    })
    gz.cmd_status(cfg_file)
    out, _ = capsys.readouterr()
    assert "backend:        file" in out
    assert "app:            opencode" in out
    assert "valid" in out


def test_status_reports_empty_cache(cfg_file: dict,
                                    capsys: pytest.CaptureFixture) -> None:
    cfg_file["cached"] = {}
    gz.cmd_status(cfg_file)
    out, _ = capsys.readouterr()
    assert "no tokens cached" in out


def test_save_writes_config_alongside_tokens(cfg_file: dict) -> None:
    """_save persists the config so subsequent invocations can pull it
    back from cache instead of re-reading env vars."""
    gz._save(cfg_file, {"access_token": "j", "refresh_token": "r",
                        "expires_at": 1})
    blob = cfg_file["tokens_path"].read_bytes()
    parsed = json.loads(blob)
    assert parsed["issuer"] == "https://oidc.example"
    assert parsed["client_id"] == CLIENT_ID
    assert parsed["client_secret"] == CLIENT_SECRET
    assert parsed["access_token"] == "j"
    # In-memory cache also updated so chained calls (token→refresh→…)
    # see the fresh values.
    assert cfg_file["cached"]["access_token"] == "j"
