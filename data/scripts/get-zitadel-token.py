#!/usr/bin/env python3
"""Fetch + refresh a Zitadel access_token (JWT) for any Zitadel OIDC app.

App-agnostic. Specify `--app NAME` (or `APP_NAME` env) to pick a logical
namespace; everything else (issuer, client_id, client_secret, tokens) is
cached under that namespace on first `login` and reused afterwards.

Subcommands:
  login    — run OIDC Authorization Code + PKCE flow once. Browser pops,
             you sign in at Zitadel, the script catches the callback on
             127.0.0.1:<port>/callback, exchanges code for tokens, stores
             {issuer, client_id, client_secret, access_token, refresh_token,
             expires_at, ...} in the chosen backend under the app's namespace.
  refresh  — exchange the cached refresh_token for a fresh access_token.
             Rotates refresh_token if Zitadel returns a new one.
  token    — print the current access_token (refreshing if expired or
             expiring within REFRESH_LEEWAY seconds). Suitable for shell
             wrappers:  git -c http.extraHeader="Authorization: Bearer
             $(get-zitadel-token.py token --app opencode)" fetch …
  status   — print human-readable expiry info + which backend is in use.
  logout   — delete the cached entry for this app from the backend.

Stdlib only as a hard floor. No pip install required. Python 3.10+.
If optional system packages are present, the script uses them transparently
for stronger at-rest secret handling.

Storage backends are tried in this order (override via STORAGE_BACKEND env):

  gi-secret      libsecret via PyGObject (`gi.repository.Secret`). Most
                 official binding, uses the same C library `secret-tool`
                 calls. Arch: python-gobject + libsecret.
  secretstorage  Pure-Python D-Bus client speaking the Secret Service API.
                 Arch: python-secretstorage.
  dbus-python    Low-level D-Bus bindings (C extension). Older but stable.
                 Arch: python-dbus.
  secret-tool    Shell-out to libsecret's CLI. No Python deps, just the
                 binary. Arch: libsecret.
  file           Plain JSON at $XDG_STATE_HOME/zitadel/tokens.json
                 (mode 0600). Always available; no encryption at rest.

`STORAGE_BACKEND=auto` (default) cascades top → bottom and picks the first
available. `STORAGE_BACKEND=<name>` forces a specific tier and errors out
if it isn't usable.

Config — precedence is CLI flag > env var > cached blob. Required for the
FIRST `login` invocation only; cached in the chosen backend under
`service=zitadel app=<APP_NAME>` afterwards, so subsequent runs need no
flags or env beyond `--app`:

  --app NAME              logical app namespace. env: APP_NAME. Required.
  --issuer URL            OIDC issuer URL (https://oidc.<hs>.<magic>).
                          env: ZITADEL_ISSUER.
  --client-id ID          OIDC application client_id.
                          env: ZITADEL_CLIENT_ID.
  --client-secret SECRET  OIDC application client_secret.
                          env: ZITADEL_CLIENT_SECRET.

Optional env (no CLI counterpart):
  STORAGE_BACKEND         see above; default `auto`
  TOKENS_PATH             only used by the file backend.
                          default $XDG_STATE_HOME/zitadel/tokens.json
                          (i.e. ~/.local/state/zitadel/tokens.json).
  KEYRING_LABEL           label shown by keyring UIs.
                          default "Zitadel OIDC tokens (<APP_NAME>)"
  REDIRECT_PORT           default 9876 (must be in the Zitadel app's
                          redirect_uris allowlist; TF registers 9876 + 8765)
  REFRESH_LEEWAY          default 60 seconds before expiry to pre-refresh
  SCOPES                  default "openid email profile offline_access"
                          (offline_access is what makes Zitadel return a
                          refresh_token — strip it at your peril)

Keyring attributes (namespaces per app):
  service=zitadel  app=<APP_NAME>

Stored blob is JSON. Config travels alongside tokens so subsequent
invocations don't need the env vars:
  {
    "issuer":        "https://oidc.<hs>.<magic>",
    "client_id":     "...",
    "client_secret": "...",
    "access_token":  "<JWT>",
    "refresh_token": "<opaque>",
    "expires_in":    3600,
    "expires_at":    <unix ts>,
    "token_type":    "Bearer",
    "scope":         "openid email profile offline_access",
    ...
  }

Exit codes:
  0  success (tokens written / token printed / logged out)
  2  any error — message on stderr
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path
from typing import Iterable


# --- env / config ----------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    """Top-level argparse with one subparser per command and a shared
    parent parser carrying the four common flags. Each flag falls back
    to its env-var equivalent if the CLI flag is omitted; the cached
    backend blob is consulted last (in `_cfg`)."""
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--app", default=os.environ.get("APP_NAME"),
        help="logical app namespace (env: APP_NAME). Required — picks "
             "the keyring entry to read/write.",
    )
    common.add_argument(
        "--issuer", default=os.environ.get("ZITADEL_ISSUER"),
        help="OIDC issuer URL, e.g. https://oidc.example "
             "(env: ZITADEL_ISSUER). Required on first login; cached after.",
    )
    common.add_argument(
        "--client-id", dest="client_id",
        default=os.environ.get("ZITADEL_CLIENT_ID"),
        help="OIDC application client_id (env: ZITADEL_CLIENT_ID). "
             "Required on first login; cached after.",
    )
    common.add_argument(
        "--client-secret", dest="client_secret",
        default=os.environ.get("ZITADEL_CLIENT_SECRET"),
        help="OIDC application client_secret (env: ZITADEL_CLIENT_SECRET). "
             "Required on first login; cached after.",
    )

    parser = argparse.ArgumentParser(
        prog="get-zitadel-token.py",
        description=(__doc__ or "").splitlines()[0] if __doc__ else None,
    )
    sub = parser.add_subparsers(dest="cmd", required=True, metavar="SUBCOMMAND")
    for cmd, desc in [
        ("login",   "run the OIDC code+PKCE flow and cache tokens + config"),
        ("refresh", "exchange the cached refresh_token for a new access_token"),
        ("token",   "print current access_token (auto-refreshes if near expiry)"),
        ("status",  "show backend, app, and cached token expiry"),
        ("logout",  "delete the cached entry for this app"),
    ]:
        sub.add_parser(cmd, help=desc, parents=[common])
    return parser


def _default_tokens_path() -> Path:
    """XDG_STATE_HOME/zitadel/tokens.json — tokens are state, not config."""
    state = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(state) / "zitadel" / "tokens.json"


# --- backends --------------------------------------------------------------
#
# Each backend exposes a uniform 3-method API:
#
#   .save(label: str, attrs: dict[str,str], blob: bytes) -> None
#   .load(attrs: dict[str,str])                          -> bytes | None
#   .clear(attrs: dict[str,str])                         -> None
#
# Plus:
#   .name: short backend identifier (matches STORAGE_BACKEND values)
#   .available: True if the backend probe succeeded at construction time
#
# Construction MUST be cheap (or at least non-fatal): the auto-detect chain
# instantiates each backend in turn and checks `available`. Failed probes
# trap their exceptions and set `available = False`.

class _GISecret:
    """libsecret via PyGObject. Most official binding on Linux."""
    name = "gi-secret"

    SCHEMA_NAME = "io.homelab.zitadel-token"

    def __init__(self, _tokens_path: Path) -> None:
        try:
            import gi  # type: ignore[import-not-found]
            gi.require_version("Secret", "1")
            from gi.repository import Secret  # type: ignore[import-not-found]
            self._S = Secret
            # Schema attrs MUST match the keys passed by `_attrs(app)` —
            # libsecret rejects lookups whose attribute names aren't
            # declared here. See https://gnome.pages.gitlab.gnome.org/
            # libsecret/SecretSchema.html.
            self._schema = Secret.Schema.new(
                self.SCHEMA_NAME,
                Secret.SchemaFlags.NONE,
                {"service": Secret.SchemaAttributeType.STRING,
                 "app":     Secret.SchemaAttributeType.STRING},
            )
            self.available = True
        except Exception:
            self.available = False

    def save(self, label: str, attrs: dict, blob: bytes) -> None:
        ok = self._S.password_store_sync(
            self._schema, attrs, self._S.COLLECTION_DEFAULT,
            label, blob.decode("utf-8"), None,
        )
        if not ok:
            raise RuntimeError("Secret.password_store_sync returned False")

    def load(self, attrs: dict) -> bytes | None:
        s = self._S.password_lookup_sync(self._schema, attrs, None)
        return s.encode("utf-8") if s else None

    def clear(self, attrs: dict) -> None:
        self._S.password_clear_sync(self._schema, attrs, None)


class _SecretStorage:
    """Pure-Python Secret Service client via jeepney."""
    name = "secretstorage"

    def __init__(self, _tokens_path: Path) -> None:
        try:
            import secretstorage  # type: ignore[import-not-found]
            self._ss = secretstorage
            self._conn = secretstorage.dbus_init()
            # Touch the default collection to ensure the service is alive.
            secretstorage.get_default_collection(self._conn)
            self.available = True
        except Exception:
            self.available = False

    def _col(self):
        col = self._ss.get_default_collection(self._conn)
        if col.is_locked():
            col.unlock()
        return col

    def save(self, label: str, attrs: dict, blob: bytes) -> None:
        col = self._col()
        for it in col.search_items(attrs):
            it.delete()
        col.create_item(label, attrs, blob, replace=True)

    def load(self, attrs: dict) -> bytes | None:
        for it in self._col().search_items(attrs):
            return it.get_secret()
        return None

    def clear(self, attrs: dict) -> None:
        for it in self._col().search_items(attrs):
            it.delete()


class _DBusPython:
    """Low-level Secret Service over dbus-python."""
    name = "dbus-python"

    SVC = "org.freedesktop.secrets"
    SVC_PATH = "/org/freedesktop/secrets"
    DEFAULT_COLLECTION = "/org/freedesktop/secrets/aliases/default"
    IF_SERVICE = "org.freedesktop.Secret.Service"
    IF_COLLECTION = "org.freedesktop.Secret.Collection"
    IF_ITEM = "org.freedesktop.Secret.Item"

    def __init__(self, _tokens_path: Path) -> None:
        try:
            import dbus  # type: ignore[import-not-found]
            self._dbus = dbus
            bus = dbus.SessionBus()
            # Hitting the service object proves the daemon is reachable.
            bus.get_object(self.SVC, self.SVC_PATH)
            self.available = True
        except Exception:
            self.available = False

    def _open(self):
        dbus = self._dbus
        bus = dbus.SessionBus()
        svc_obj = bus.get_object(self.SVC, self.SVC_PATH)
        iface = dbus.Interface(svc_obj, self.IF_SERVICE)
        _, sess = iface.OpenSession("plain", dbus.String("", variant_level=1))
        col_obj = bus.get_object(self.SVC, self.DEFAULT_COLLECTION)
        return bus, iface, sess, col_obj

    def _search(self, attrs: dict):
        bus, iface, sess, _ = self._open()
        unlocked, locked = iface.SearchItems(attrs)
        if not unlocked and locked:
            try:
                iface.Unlock(locked)
                unlocked, _ = iface.SearchItems(attrs)
            except Exception:
                pass
        return bus, sess, list(unlocked)

    def save(self, label: str, attrs: dict, blob: bytes) -> None:
        dbus = self._dbus
        bus, iface, sess, col_obj = self._open()
        # Replace strategy: delete existing matches, then CreateItem.
        for path in list(iface.SearchItems(attrs)[0]) + list(iface.SearchItems(attrs)[1]):
            dbus.Interface(bus.get_object(self.SVC, path), self.IF_ITEM).Delete()
        iface_col = dbus.Interface(col_obj, self.IF_COLLECTION)
        props = {
            f"{self.IF_ITEM}.Label": label,
            f"{self.IF_ITEM}.Attributes": dbus.Dictionary(attrs, signature="ss"),
        }
        secret = (sess, dbus.ByteArray(b""), dbus.ByteArray(blob), "text/plain")
        iface_col.CreateItem(props, secret, True)

    def load(self, attrs: dict) -> bytes | None:
        dbus = self._dbus
        bus, sess, items = self._search(attrs)
        if not items:
            return None
        item = dbus.Interface(bus.get_object(self.SVC, items[0]), self.IF_ITEM)
        _, _, blob, _ = item.GetSecret(sess)
        return bytes(blob)

    def clear(self, attrs: dict) -> None:
        dbus = self._dbus
        bus, _, items = self._search(attrs)
        for path in items:
            dbus.Interface(bus.get_object(self.SVC, path), self.IF_ITEM).Delete()


class _SecretTool:
    """Shell-out to libsecret's `secret-tool` CLI. Zero Python deps."""
    name = "secret-tool"

    def __init__(self, _tokens_path: Path) -> None:
        self.available = shutil.which("secret-tool") is not None

    def _attr_args(self, attrs: dict) -> list[str]:
        out: list[str] = []
        for k, v in attrs.items():
            out += [k, v]
        return out

    def save(self, label: str, attrs: dict, blob: bytes) -> None:
        r = subprocess.run(
            ["secret-tool", "store", "--label", label, *self._attr_args(attrs)],
            input=blob, capture_output=True,
        )
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode().strip() or "secret-tool store failed")

    def load(self, attrs: dict) -> bytes | None:
        r = subprocess.run(
            ["secret-tool", "lookup", *self._attr_args(attrs)],
            capture_output=True,
        )
        if r.returncode != 0 or not r.stdout:
            return None
        return r.stdout.rstrip(b"\n")

    def clear(self, attrs: dict) -> None:
        r = subprocess.run(
            ["secret-tool", "clear", *self._attr_args(attrs)],
            capture_output=True,
        )
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode().strip() or "secret-tool clear failed")


class _FileBackend:
    """Plain JSON at TOKENS_PATH, mode 0600. Always available."""
    name = "file"

    def __init__(self, tokens_path: Path) -> None:
        self.path = tokens_path
        self.available = True

    def save(self, _label: str, _attrs: dict, blob: bytes) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".new")
        tmp.write_bytes(blob)
        tmp.chmod(0o600)
        tmp.replace(self.path)

    def load(self, _attrs: dict) -> bytes | None:
        if not self.path.exists():
            return None
        return self.path.read_bytes()

    def clear(self, _attrs: dict) -> None:
        if self.path.exists():
            self.path.unlink()


# Order matters: best → worst. File is always available so the cascade
# never dead-ends.
_BACKEND_CHAIN: list[type] = [
    _GISecret,
    _SecretStorage,
    _DBusPython,
    _SecretTool,
    _FileBackend,
]
_BY_NAME = {cls.name: cls for cls in _BACKEND_CHAIN}


def _pick_backend(tokens_path: Path):
    requested = os.environ.get("STORAGE_BACKEND", "auto")
    if requested == "auto":
        for cls in _BACKEND_CHAIN:
            b = cls(tokens_path)
            if b.available:
                return b
        # _FileBackend is unconditionally available, so we never reach here
        # unless someone removes it from the chain.
        sys.exit("error: no usable backend found (unreachable)")
    if requested not in _BY_NAME:
        sys.exit(f"error: unknown STORAGE_BACKEND {requested!r} "
                 f"(want one of: auto, {', '.join(_BY_NAME)})")
    b = _BY_NAME[requested](tokens_path)
    if not b.available:
        sys.exit(f"error: STORAGE_BACKEND={requested} is not available "
                 f"(import or daemon probe failed)")
    return b


# --- top-level config ------------------------------------------------------

# Maps internal cfg keys → (CLI flag, env var). Used by _require_config to
# produce clean "missing X" errors.
_CFG_SOURCES = {
    "issuer":        ("--issuer",        "ZITADEL_ISSUER"),
    "client_id":     ("--client-id",     "ZITADEL_CLIENT_ID"),
    "client_secret": ("--client-secret", "ZITADEL_CLIENT_SECRET"),
}


def _attrs(app: str) -> dict[str, str]:
    """Per-app Secret Service attributes. Namespaced by app name so the
    lookup key is stable across config rotations — client_id can change
    without orphaning the cached entry."""
    return {"service": "zitadel", "app": app}


def _cfg(args: argparse.Namespace) -> dict:
    """Resolve config from CLI args (already env-overlaid by argparse
    defaults) + cached backend blob.

    Precedence: CLI flag > env var > cached blob > unset (handled per
    subcommand via _require_config). Loads the cached blob eagerly so
    subcommands that only need tokens (status, token, logout) don't have
    to call the backend a second time.
    """
    if not args.app:
        sys.exit("error: --app NAME or APP_NAME env var required")

    tokens_path = Path(os.environ.get("TOKENS_PATH",
                                      str(_default_tokens_path()))).expanduser()
    backend = _pick_backend(tokens_path)

    cached: dict = {}
    try:
        blob = backend.load(_attrs(args.app))
        if blob:
            cached = json.loads(blob)
    except Exception:
        # The backend probe passed in __init__ but the actual lookup raised
        # (e.g. keyring locked). Treat as "no cache" — subcommands that
        # need tokens will report the right error via _require_tokens.
        cached = {}

    issuer = (args.issuer or cached.get("issuer") or "").rstrip("/")
    client_id = args.client_id or cached.get("client_id") or ""
    client_secret = args.client_secret or cached.get("client_secret") or ""

    return {
        "app_name":      args.app,
        "backend":       backend,
        "tokens_path":   tokens_path,
        "issuer":        issuer,
        "client_id":     client_id,
        "client_secret": client_secret,
        "keyring_label": os.environ.get("KEYRING_LABEL",
                                        f"Zitadel OIDC tokens ({args.app})"),
        "redirect_port": int(os.environ.get("REDIRECT_PORT", "9876")),
        "scopes":        os.environ.get("SCOPES",
                                        "openid email profile offline_access"),
        "leeway":        int(os.environ.get("REFRESH_LEEWAY", "60")),
        "cached":        cached,
    }


def _require_config(c: dict) -> None:
    missing = [f"{flag}/{env}" for key, (flag, env) in _CFG_SOURCES.items()
               if not c[key]]
    if missing:
        sys.exit(
            f"error: missing config — supply {', '.join(missing)} via "
            f"flag/env, or run `login` once with them set so they get "
            f"cached for this app"
        )


def _require_tokens(c: dict) -> dict:
    if not c["cached"] or not c["cached"].get("access_token"):
        sys.exit(f"error: no tokens cached in {c['backend'].name} backend — "
                 f"run `login` first")
    return c["cached"]


# --- storage helpers (dispatch through backend) ----------------------------

def _save(c: dict, tokens: dict) -> None:
    """Persist config + tokens as one blob. Config is carried so subsequent
    invocations (refresh / token / status / logout) don't need env vars."""
    blob_dict = {
        "issuer":        c["issuer"],
        "client_id":     c["client_id"],
        "client_secret": c["client_secret"],
        **tokens,
    }
    blob = json.dumps(blob_dict, indent=2).encode("utf-8")
    try:
        c["backend"].save(c["keyring_label"], _attrs(c["app_name"]), blob)
    except Exception as e:
        sys.exit(f"error: {c['backend'].name} save failed: {e}")
    # Keep the in-memory cache in sync so the same cfg dict can drive
    # follow-up subcommands (cmd_token calls cmd_refresh, which _saves,
    # then prints the freshly-refreshed access_token).
    c["cached"] = blob_dict


def _clear(c: dict) -> None:
    try:
        c["backend"].clear(_attrs(c["app_name"]))
    except Exception as e:
        sys.exit(f"error: {c['backend'].name} clear failed: {e}")
    c["cached"] = {}


def _fingerprint(s: str) -> str:
    """Short non-leaking summary of a token for human-readable diffs:
    `<first6>…<last6> (<n>c)`. Lets the user see when access_token /
    refresh_token actually changed without dumping the whole secret."""
    if not s:
        return "<empty>"
    if len(s) <= 16:
        return f"<{len(s)}c>"
    return f"{s[:6]}…{s[-6:]} ({len(s)}c)"


def _location_lines(c: dict) -> list[str]:
    """Human-readable description of WHERE the cached entry lives.

    For Secret Service backends (gi-secret / secretstorage / dbus-python /
    secret-tool) we can't easily surface the underlying D-Bus object path
    from inside the script — print the lookup attrs + the `secret-tool`
    command that reveals it instead. For the file backend, print the
    absolute path.
    """
    lines = [
        f"backend:        {c['backend'].name}",
        f"app:            {c['app_name']}",
    ]
    if c["backend"].name == "file":
        lines.append(f"path:           {c['tokens_path']}")
    else:
        lines += [
            f"keyring label:  {c['keyring_label']}",
            f"keyring attrs:  service=zitadel app={c['app_name']}",
            f"inspect with:   secret-tool search service zitadel "
            f"app {c['app_name']}",
        ]
    return lines


# --- crypto + HTTP helpers -------------------------------------------------

def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _post_token(c: dict, form: dict) -> dict:
    body = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(f"{c['issuer']}/oauth/v2/token",
                                 data=body, method="POST")
    creds = base64.b64encode(
        f"{c['client_id']}:{c['client_secret']}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"error: token endpoint returned {e.code}: {e.read().decode()}")


def _stamp(tok: dict) -> dict:
    """Add absolute expires_at unix timestamp to a token response."""
    tok["expires_at"] = int(time.time()) + int(tok.get("expires_in", 3600))
    return tok


# --- subcommands -----------------------------------------------------------

def cmd_login(c: dict) -> None:
    _require_config(c)
    verifier = _b64url(secrets.token_bytes(64))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    state = secrets.token_urlsafe(24)
    redirect = f"http://127.0.0.1:{c['redirect_port']}/callback"

    qs = urllib.parse.urlencode({
        "client_id":             c["client_id"],
        "response_type":         "code",
        "scope":                 c["scopes"],
        "redirect_uri":          redirect,
        "code_challenge":        challenge,
        "code_challenge_method": "S256",
        "state":                 state,
    })
    auth_url = f"{c['issuer']}/oauth/v2/authorize?{qs}"

    captured: dict = {}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_a, **_k) -> None: pass

        def do_GET(self) -> None:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [None])[0] != state:
                self.send_response(400); self.end_headers()
                self.wfile.write(b"state mismatch")
                captured["error"] = "state mismatch"
                return
            if "error" in q:
                msg = f"{q['error'][0]}: {q.get('error_description', [''])[0]}"
                self.send_response(400); self.end_headers()
                self.wfile.write(msg.encode())
                captured["error"] = msg
                return
            captured["code"] = q["code"][0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<h1>Authenticated. You can close this tab.</h1>")

    print(f"opening browser; if it doesn't pop, visit:\n  {auth_url}",
          file=sys.stderr)
    webbrowser.open(auth_url)

    with http.server.HTTPServer(("127.0.0.1", c["redirect_port"]), H) as srv:
        srv.timeout = 300
        while "code" not in captured and "error" not in captured:
            srv.handle_request()

    if "error" in captured:
        sys.exit(f"error: {captured['error']}")

    tok = _post_token(c, {
        "grant_type":    "authorization_code",
        "code":          captured["code"],
        "redirect_uri":  redirect,
        "code_verifier": verifier,
    })
    _save(c, _stamp(tok))
    print("saved. cached entry:", file=sys.stderr)
    for line in _location_lines(c):
        print(f"  {line}", file=sys.stderr)


def cmd_refresh(c: dict) -> dict:
    _require_config(c)
    tok = _require_tokens(c)
    rt = tok.get("refresh_token")
    if not rt:
        sys.exit("error: no refresh_token in cache — re-run `login`")

    # Snapshot pre-refresh values so we can show a meaningful diff.
    old_at = tok.get("access_token", "")
    old_rt = rt
    old_exp = int(tok.get("expires_at", 0))

    new = _post_token(c, {"grant_type": "refresh_token", "refresh_token": rt})
    # Zitadel may or may not rotate the refresh_token; carry the new one
    # if present, keep the old if absent. Drop the cached config fields so
    # `_save` doesn't double-write them.
    merged = {k: v for k, v in tok.items() if k not in _CFG_SOURCES}
    merged.update(new)
    _save(c, _stamp(merged))

    cur = c["cached"]
    now = int(time.time())
    new_exp = int(cur.get("expires_at", 0))
    new_at = cur.get("access_token", "")
    new_rt = cur.get("refresh_token", "")

    print("refreshed:", file=sys.stderr)
    print(f"  access_token:   {_fingerprint(new_at)} "
          f"(was {_fingerprint(old_at)})", file=sys.stderr)
    print(f"  refresh_token:  "
          f"{'rotated → ' + _fingerprint(new_rt) if new_rt != old_rt else 'unchanged'}",
          file=sys.stderr)
    print(f"  expires_in:     {new_exp - now}s "
          f"(was {old_exp - now}s)", file=sys.stderr)
    return cur


def cmd_token(c: dict) -> None:
    tok = _require_tokens(c)
    if int(time.time()) >= tok.get("expires_at", 0) - c["leeway"]:
        tok = cmd_refresh(c)
    print(tok["access_token"])


def cmd_status(c: dict) -> None:
    for line in _location_lines(c):
        print(line)
    if not c["cached"]:
        print("status:         no tokens cached — run `login` first")
        return
    tok = c["cached"]
    now = int(time.time())
    left = tok.get("expires_at", 0) - now
    print(f"issuer:         {tok.get('issuer', '?')}")
    print(f"client_id:      {tok.get('client_id', '?')}")
    print(f"access_token:   {'present' if tok.get('access_token') else 'MISSING'}")
    print(f"refresh_token:  {'present' if tok.get('refresh_token') else 'MISSING'}")
    print(f"expires_in:     {left}s ({'expired' if left <= 0 else 'valid'})")
    print(f"scope:          {tok.get('scope', '?')}")


def cmd_logout(c: dict) -> None:
    _clear(c)
    print("cleared", file=sys.stderr)


def main() -> None:
    args = _build_parser().parse_args()
    c = _cfg(args)
    if args.cmd == "login":
        cmd_login(c)
    elif args.cmd == "refresh":
        cmd_refresh(c)  # prints its own summary to stderr
    elif args.cmd == "token":
        cmd_token(c)
    elif args.cmd == "status":
        cmd_status(c)
    elif args.cmd == "logout":
        cmd_logout(c)
    else:  # argparse with required=True makes this unreachable
        sys.exit(f"error: unknown subcommand {args.cmd!r}")


if __name__ == "__main__":
    main()
