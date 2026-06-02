#!/usr/bin/env python3
"""Jellyfin bootstrap + reconcile for Zitadel SSO + Quick Connect.

Idempotent. Re-runs are safe: each step compares current state to desired
state and acts only on diffs. Hash-gated state cache lives on the shared
jellyfin-config PVC at SEED_STATE_PATH.

Reconcile order:

  1. reconcile_startup
       - Walk Jellyfin's first-run /Startup wizard if the server is fresh.
       - Create the hidden `_seed` admin with the Vault-managed password.
       - Skipped on subsequent runs (Jellyfin returns 401 on /Startup/* once
         the wizard is complete).

  2. login_seed
       - POST /Users/AuthenticateByName as `_seed` to obtain an AccessToken.
       - All subsequent calls carry the standard X-Emby-Authorization header
         with `Token="<access-token>"` appended.

  3. reconcile_seed_admin
       - Ensure `_seed`'s policy is IsAdministrator=true, IsHidden=true so
         the login picker doesn't show this account to humans.

  4. reconcile_users
       - Ensure each user in $USERS exists as a local Jellyfin account.
       - Set policy: admin/regular based on $ADMIN_USERS membership.
       - Clear the password (POST /Users/<id>/Password with ResetPassword=true)
         so the web-form path can't auth them — only OIDC + Quick Connect.

  5. reconcile_sso_plugin
       - POST /sso/OID/Add/<provider> with the OIDC config payload (issuer,
         client_id, client_secret, scopes, claim mapping, default-provider).
       - Hash-gated so an unchanged config is a no-op.

  6. reconcile_branding
       - POST /System/Configuration/branding with a LoginDisclaimer that
         injects the "Login with Zitadel" button on the /web/ login page
         (the 9p4 plugin doesn't auto-inject — its README directs users
         to paste the form HTML into the Branding "Login disclaimer"
         field). Hash-gated.

API endpoints used (Jellyfin 10.10+):

  GET  /System/Info/Public       — alive probe (no auth).
  GET  /Startup/Configuration    — 200 in wizard mode, 401 after Complete.
  POST /Startup/Configuration    — locale during wizard.
  POST /Startup/User             — first-admin creation during wizard.
  POST /Startup/RemoteAccess     — remote-access toggle during wizard.
  POST /Startup/Complete         — finalize wizard.
  POST /Users/AuthenticateByName — body {Username, Pw} → {AccessToken, User}.
  GET  /Users                    — list all users.
  POST /Users/New                — body {Name, Password?} → user object.
  GET  /Users/<id>               — fetch user with .Policy.
  POST /Users/<id>/Policy        — replace user policy (full object).
  POST /Users/<id>/Password      — body {ResetPassword: true} clears it.

  POST /sso/OID/Add/<provider>   — 9p4/jellyfin-plugin-sso config write.
  GET  /sso/OID/Get/<provider>   — read current plugin config (404 if absent).
  GET  /Branding/Configuration   — current BrandingOptions.
  POST /System/Configuration/branding — update BrandingOptions
                                  (generic named-config setter).
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import logging
import os
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Optional

LOG = logging.getLogger("seed")

# Endpoints whose request body contains secrets — never log the body.
SENSITIVE_PATHS = (
    "/Users/AuthenticateByName",
    "/Startup/User",
    "/Users/New",
    "/Users/",            # /Users/<id>/Password — body has CurrentPw/NewPw
    "/sso/OID/Add",
)

# Plugin-config keys that must never appear in logs.
SENSITIVE_SSO_KEYS = frozenset({"OidClientId", "OidSecret"})

# Stable device-id keeps the AccessToken row tied to one row in
# /Devices instead of accumulating one new device per apply.
SEED_DEVICE_ID = "jellyfin-seed-" + hashlib.sha256(b"jellyfin-seed").hexdigest()[:16]


@dataclasses.dataclass
class Settings:
    jellyfin_url: str
    jellyfin_public_url: str
    users: list[str]
    admin_users: list[str]
    seed_user: str
    secrets_dir: Path
    seed_state_path: Path
    oidc_provider: str
    oidc_issuer_url: str
    oidc_button_text: str

    @classmethod
    def from_env(cls) -> "Settings":
        users_csv = os.environ.get("USERS", "").strip()
        users = [u.strip() for u in users_csv.split(",") if u.strip()]
        if not users:
            die("USERS env var is empty — at least one user required")

        admins_csv = os.environ.get("ADMIN_USERS", "").strip()
        admins = [u.strip() for u in admins_csv.split(",") if u.strip()]

        return cls(
            jellyfin_url=require_env("JELLYFIN_URL").rstrip("/"),
            jellyfin_public_url=require_env("JELLYFIN_PUBLIC_URL").rstrip("/"),
            users=users,
            admin_users=admins,
            seed_user=os.environ.get("SEED_USER", "_seed"),
            secrets_dir=Path(os.environ.get("SECRETS_DIR", "/mnt/secrets")),
            seed_state_path=Path(os.environ.get("SEED_STATE_PATH", "")),
            oidc_provider=os.environ.get("OIDC_PROVIDER", "zitadel"),
            oidc_issuer_url=os.environ.get("OIDC_ISSUER_URL", "").rstrip("/"),
            oidc_button_text=os.environ.get("OIDC_BUTTON_TEXT", "Login with Zitadel"),
        )


class JellyfinError(RuntimeError):
    """API call failed in a way the script can't recover from."""


def require_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        die(f"{name} env var is required")
    return val


def die(msg: str, exc: Optional[BaseException] = None) -> None:
    LOG.error(msg)
    if exc is not None and not isinstance(exc, JellyfinError):
        LOG.error("traceback:\n%s", "".join(traceback.format_exception(exc)))
    sys.exit(1)


def _is_transient_network_error(exc: urllib.error.URLError) -> bool:
    """Return True for transport-layer errors worth retrying."""
    reason = exc.reason
    if isinstance(reason, ConnectionError):
        return True
    if isinstance(reason, OSError):
        # 111 ECONNREFUSED, 104 ECONNRESET, 110 ETIMEDOUT, 113 EHOSTUNREACH,
        # -2/-3 getaddrinfo failures.
        if getattr(reason, "errno", None) in (111, 104, 110, 113, -2, -3):
            return True
    if isinstance(reason, TimeoutError):
        return True
    msg = str(reason).lower()
    return any(s in msg for s in (
        "connection refused", "connection reset", "name or service not known",
        "temporary failure in name resolution", "timed out", "no route to host",
    ))


def read_secret(secrets_dir: Path, name: str) -> str:
    f = secrets_dir / name
    if not f.is_file():
        raise JellyfinError(
            f"missing secret '{name}' at {f} — Vault CSI sync may have failed"
        )
    return f.read_text().rstrip("\n")


class JellyfinClient:
    """HTTP client tailored to Jellyfin's auth + retry semantics."""

    NETWORK_RETRIES = 8
    NETWORK_RETRY_BASE_DELAY_S = 1.0

    def __init__(self, base_url: str):
        self.base = base_url
        self.token: Optional[str] = None
        self.client_name = "jellyfin-seed"
        self.device_name = "seed"
        self.device_id = SEED_DEVICE_ID
        self.app_version = "1.0.0"

    def _emby_auth_header(self) -> str:
        """Build the X-Emby-Authorization header. Required on every authed
        endpoint; the Token clause is appended once we've logged in."""
        parts = [
            f'Client="{self.client_name}"',
            f'Device="{self.device_name}"',
            f'DeviceId="{self.device_id}"',
            f'Version="{self.app_version}"',
        ]
        if self.token:
            parts.append(f'Token="{self.token}"')
        return "MediaBrowser " + ", ".join(parts)

    def _request(
        self,
        method: str,
        path: str,
        body: Any = None,
        timeout: float = 30.0,
        expect_json: bool = True,
    ) -> Any:
        url = self.base + path
        sensitive = any(path.startswith(p) for p in SENSITIVE_PATHS)
        data = None
        headers = {
            "Accept": "application/json",
            "X-Emby-Authorization": self._emby_auth_header(),
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        if sensitive:
            LOG.debug("%s %s (body redacted)", method, path)
        else:
            LOG.debug("%s %s body=%s", method, path, body)

        last_err: Optional[BaseException] = None
        for attempt in range(self.NETWORK_RETRIES):
            req = urllib.request.Request(url, method=method, data=data, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    raw = resp.read()
                    if not expect_json or not raw:
                        return None
                    try:
                        return json.loads(raw)
                    except json.JSONDecodeError as e:
                        raise JellyfinError(
                            f"{method} {path} returned non-JSON (status={resp.status}, "
                            f"content-type={resp.headers.get('Content-Type')!r}): {raw[:300]!r}"
                        ) from e
            except urllib.error.HTTPError as e:
                # 4xx/5xx are responses, not transport faults — never retried.
                err_body = e.read().decode("utf-8", errors="replace")[:500]
                raise JellyfinError(
                    f"{method} {path} -> HTTP {e.code} {e.reason}: {err_body!r}"
                ) from e
            except urllib.error.URLError as e:
                if not _is_transient_network_error(e) or attempt == self.NETWORK_RETRIES - 1:
                    raise JellyfinError(
                        f"{method} {path} -> network error: {e.reason}"
                    ) from e
                delay = self.NETWORK_RETRY_BASE_DELAY_S * (2 ** attempt)
                LOG.info("%s %s transient (%s); retry %d/%d in %.1fs",
                         method, path, e.reason, attempt + 1,
                         self.NETWORK_RETRIES - 1, delay)
                time.sleep(delay)
                last_err = e

        # Defensive — loop above always returns or raises.
        raise JellyfinError(f"{method} {path} -> exhausted retries: {last_err}")

    # --- Liveness ----------------------------------------------------------

    def wait_until_alive(self, timeout_s: int = 300, interval_s: float = 5.0) -> dict:
        """Poll /System/Info/Public until 200. Returns parsed body."""
        deadline = time.monotonic() + timeout_s
        last_err: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                return self._request("GET", "/System/Info/Public", timeout=10)
            except JellyfinError as e:
                last_err = e
                LOG.info("Jellyfin not ready yet (%s)", str(e).split(":", 1)[0])
                time.sleep(interval_s)
        raise JellyfinError(
            f"Jellyfin /System/Info/Public never responded within {timeout_s}s; "
            f"last: {last_err}"
        )

    # --- Startup wizard ----------------------------------------------------

    def is_in_startup_wizard(self) -> bool:
        """True if Jellyfin is in first-run wizard mode.

        /Startup/Configuration is gated by the FirstTimeSetupOrElevated
        policy: it returns 200 during the wizard and 401 once
        /Startup/Complete has been called. We exploit this to detect mode
        without needing an admin token (which we don't have yet)."""
        try:
            self._request("GET", "/Startup/Configuration", timeout=10)
            return True
        except JellyfinError as e:
            if "HTTP 401" in str(e) or "HTTP 403" in str(e):
                return False
            raise

    def startup_set_configuration(self) -> None:
        self._request(
            "POST", "/Startup/Configuration",
            body={
                "UICulture": "en-US",
                "MetadataCountryCode": "US",
                "PreferredMetadataLanguage": "en",
            },
            expect_json=False,
        )

    def startup_initialize_user(self) -> dict:
        """GET /Startup/User triggers `_userManager.InitializeAsync()` which
        creates the default user when the DB is empty. POST /Startup/User
        will throw `Sequence contains no elements` (HTTP 500) if this isn't
        called first — the official Jellyfin web wizard hits GET to
        populate the form, side-effect-creating the user along the way."""
        resp = self._request("GET", "/Startup/User")
        if not isinstance(resp, dict):
            raise JellyfinError(f"unexpected GET /Startup/User response: {resp!r}")
        return resp

    def startup_create_admin(self, name: str, password: str) -> None:
        # Jellyfin's `_userManager.InitializeAsync()` (triggered by GET
        # /Startup/User above) is lazy/async — on cold start the default
        # user can take a minute or more to actually land. The POST that
        # renames it then 500s with `Sequence contains no elements`.
        # Retry until the user exists.
        for attempt in range(20):
            try:
                self._request(
                    "POST", "/Startup/User",
                    body={"Name": name, "Password": password},
                    expect_json=False,
                )
                return
            except JellyfinError as e:
                if (
                    "HTTP 500" in str(e)
                    and "Sequence contains no elements" in str(e)
                    and attempt < 19
                ):
                    delay = 5.0
                    LOG.info("default user not yet materialized; retry %d/19 in %.0fs",
                             attempt + 1, delay)
                    time.sleep(delay)
                    # Re-trigger InitializeAsync via GET in case it
                    # silently bailed the first time.
                    try:
                        self._request("GET", "/Startup/User", timeout=10)
                    except JellyfinError:
                        pass
                    continue
                raise

    def startup_set_remote_access(self, enable: bool = True) -> None:
        self._request(
            "POST", "/Startup/RemoteAccess",
            body={"EnableRemoteAccess": enable, "EnableAutomaticPortMapping": False},
            expect_json=False,
        )

    def startup_complete(self) -> None:
        self._request("POST", "/Startup/Complete", expect_json=False)

    # --- Auth --------------------------------------------------------------

    def authenticate_by_name(self, username: str, password: str) -> dict:
        resp = self._request(
            "POST", "/Users/AuthenticateByName",
            body={"Username": username, "Pw": password},
        )
        if not isinstance(resp, dict) or "AccessToken" not in resp:
            raise JellyfinError(
                f"unexpected /Users/AuthenticateByName response: keys={list(resp or [])}"
            )
        self.token = resp["AccessToken"]
        return resp

    # --- Users -------------------------------------------------------------

    def list_users(self) -> list[dict]:
        resp = self._request("GET", "/Users")
        if not isinstance(resp, list):
            raise JellyfinError(f"unexpected /Users response: {resp!r}")
        return resp

    def create_user(self, name: str, password: Optional[str] = None) -> dict:
        body: dict = {"Name": name}
        if password:
            body["Password"] = password
        resp = self._request("POST", "/Users/New", body=body)
        if not isinstance(resp, dict) or "Id" not in resp:
            raise JellyfinError(f"unexpected /Users/New response: {resp!r}")
        return resp

    def get_user(self, user_id: str) -> dict:
        resp = self._request("GET", f"/Users/{user_id}")
        if not isinstance(resp, dict):
            raise JellyfinError(f"unexpected /Users/{user_id} response: {resp!r}")
        return resp

    def get_user_policy(self, user_id: str) -> dict:
        user = self.get_user(user_id)
        policy = user.get("Policy")
        if not isinstance(policy, dict):
            raise JellyfinError(f"user {user_id} missing Policy: keys={list(user)}")
        return policy

    def update_user_policy(self, user_id: str, policy: dict) -> None:
        self._request(
            "POST", f"/Users/{user_id}/Policy",
            body=policy,
            expect_json=False,
        )

    def reset_user_password(self, user_id: str) -> None:
        """Clear a user's password — admin-only operation, valid only
        for non-admin target users. Jellyfin 10.11+ enforces that admin
        users cannot have empty passwords; calling this on an admin
        will 400 with `Admin user passwords must not be empty`."""
        self._request(
            "POST", f"/Users/{user_id}/Password",
            body={"ResetPassword": True},
            expect_json=False,
        )

    def set_user_password(self, user_id: str, password: str) -> None:
        """Set a user's password (admin caller, no CurrentPw needed).
        For admin target users, this is the only way to keep the
        Jellyfin DB consistent — Jellyfin rejects empty admin passwords."""
        self._request(
            "POST", f"/Users/{user_id}/Password",
            body={"ResetPassword": False, "NewPw": password},
            expect_json=False,
        )

    # --- SSO plugin --------------------------------------------------------

    def sso_get_provider(self, provider: str) -> Optional[dict]:
        try:
            return self._request(
                "GET", f"/sso/OID/Get/{urllib.parse.quote(provider)}"
            )
        except JellyfinError as e:
            if "HTTP 404" in str(e):
                return None
            raise

    def sso_set_provider(self, provider: str, config: dict) -> None:
        # Plugin endpoints can 404 briefly after Jellyfin starts if the
        # plugin loader hasn't registered routes yet. Retry a few times
        # before surfacing the failure.
        for attempt in range(6):
            try:
                self._request(
                    "POST", f"/sso/OID/Add/{urllib.parse.quote(provider)}",
                    body=config,
                    expect_json=False,
                )
                return
            except JellyfinError as e:
                if "HTTP 404" in str(e) and attempt < 5:
                    delay = 2.0 * (attempt + 1)
                    LOG.info("SSO plugin route not yet registered; retry %d/5 in %.0fs",
                             attempt + 1, delay)
                    time.sleep(delay)
                    continue
                raise

    # --- Branding ----------------------------------------------------------

    def get_branding(self) -> dict:
        # /Branding/Configuration is unauthenticated and always returns
        # the current BrandingOptions (LoginDisclaimer, CustomCss,
        # SplashscreenEnabled).
        resp = self._request("GET", "/Branding/Configuration")
        if not isinstance(resp, dict):
            raise JellyfinError(f"unexpected /Branding/Configuration response: {resp!r}")
        return resp

    def update_branding(self, branding: dict) -> None:
        # Generic named-config setter accepts a JsonDocument that maps
        # to BrandingOptions for the "branding" key.
        self._request(
            "POST", "/System/Configuration/branding",
            body=branding,
            expect_json=False,
        )


# --- Hash-gated state cache -------------------------------------------------

STATE_VERSION = 1


def section_hash(*parts: Any) -> str:
    """Stable hash over a tuple of inputs. Each part is JSON-serialized
    with sort_keys=True so dict/list ordering doesn't shift the digest."""
    h = hashlib.sha256()
    for p in parts:
        h.update(json.dumps(p, sort_keys=True, default=str).encode("utf-8"))
        h.update(b"\x1e")  # ASCII record separator between parts
    return h.hexdigest()


def load_seed_state(path: Path) -> dict:
    """Return parsed state dict, or fresh empty one. Tolerates
    missing/corrupt file — a hash miss just forces re-run."""
    if not path.parts or not path.is_file():
        return {"version": STATE_VERSION, "sections": {}}
    try:
        raw = path.read_text()
        data = json.loads(raw) if raw.strip() else {}
    except (OSError, json.JSONDecodeError) as e:
        LOG.warning("seed-state at %s unreadable (%s); treating as empty", path, e)
        return {"version": STATE_VERSION, "sections": {}}
    if not isinstance(data, dict) or "sections" not in data:
        return {"version": STATE_VERSION, "sections": {}}
    return data


def save_seed_state(path: Path, state: dict) -> None:
    """Atomic write: tmpfile in same dir, fsync, rename."""
    if not path.parts:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def section_cached(state: dict, section: str, current_hash: str) -> bool:
    prev = (state.get("sections") or {}).get(section, {}).get("hash")
    return prev == current_hash


def record_section(state: dict, section: str, current_hash: str) -> None:
    state.setdefault("sections", {})[section] = {
        "hash": current_hash,
        "applied_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    state["version"] = STATE_VERSION


# --- Reconcile steps --------------------------------------------------------


def reconcile_startup(client: JellyfinClient, settings: Settings) -> None:
    """Drive the first-run wizard with a hidden `_seed` admin if needed."""
    client.wait_until_alive()
    if not client.is_in_startup_wizard():
        LOG.info("Jellyfin already past startup wizard")
        return

    seed_pw = read_secret(settings.secrets_dir, "seed_admin_password")
    LOG.info("running first-run wizard with seed user '%s'", settings.seed_user)
    client.startup_set_configuration()
    # GET /Startup/User must run BEFORE POST /Startup/User — the GET
    # handler calls _userManager.InitializeAsync() which creates the
    # default first user, then the POST renames it. Skipping the GET
    # leaves _userManager.Users empty and the POST 500s with
    # "Sequence contains no elements" (verified against
    # Jellyfin v10.10.5 StartupController source).
    client.startup_initialize_user()
    client.startup_create_admin(settings.seed_user, seed_pw)
    client.startup_set_remote_access(enable=True)
    client.startup_complete()
    LOG.info("startup wizard complete")
    # Jellyfin reloads internal state after /Startup/Complete; wait for the
    # API to come back before login.
    client.wait_until_alive()


def login_seed(client: JellyfinClient, settings: Settings) -> dict:
    seed_pw = read_secret(settings.secrets_dir, "seed_admin_password")
    LOG.info("logging in as seed user '%s'", settings.seed_user)
    resp = client.authenticate_by_name(settings.seed_user, seed_pw)
    user = resp.get("User") or {}
    LOG.info("seed login OK (id=%s)", user.get("Id"))
    return user


def desired_seed_policy(current: dict) -> dict:
    """Hidden admin policy. Merge onto whatever Jellyfin returned so we
    don't drop any unknown future fields."""
    out = dict(current)
    out["IsAdministrator"] = True
    out["IsHidden"] = True
    out["EnableUserPreferenceAccess"] = False
    out["IsDisabled"] = False
    return out


def desired_user_policy(current: dict, *, is_admin: bool) -> dict:
    out = dict(current)
    out["IsAdministrator"] = bool(is_admin)
    out["IsHidden"] = False
    out["IsDisabled"] = False
    out["EnableAllFolders"] = True
    out["EnableUserPreferenceAccess"] = True
    return out


def reconcile_seed_admin(client: JellyfinClient, seed_user: dict) -> None:
    user_id = seed_user.get("Id")
    if not user_id:
        raise JellyfinError("seed user object missing Id")
    current = client.get_user_policy(user_id)
    desired = desired_seed_policy(current)
    if current == desired:
        LOG.info("seed admin policy already correct")
        return
    LOG.info("PATCHing seed admin policy: hidden=true, admin=true")
    client.update_user_policy(user_id, desired)


def reconcile_users(client: JellyfinClient, settings: Settings) -> None:
    """Ensure each non-seed user exists with the right policy and the
    right password state.

    Admin users get a Vault-managed random password (Jellyfin 10.11+
    forbids empty passwords for admins). This password is functionally
    write-only — humans don't type it; once they've OIDC-logged-in once,
    the SSO plugin pins their AuthenticationProviderId and the
    password-form path stops working for them anyway.

    Non-admin users stay passwordless via ResetPassword=true so the web
    login form refuses to authenticate them — OIDC is the only path."""
    existing = {u["Name"]: u for u in client.list_users()}
    LOG.info("existing users: %s", sorted(existing.keys()))

    admin_set = set(settings.admin_users)

    for name in settings.users:
        if name == settings.seed_user:
            continue
        is_admin = name in admin_set
        if name in existing:
            user = existing[name]
            LOG.info("user '%s' exists (id=%s); reconciling policy + password",
                     name, user.get("Id"))
        else:
            LOG.info("creating user '%s' (admin=%s)", name, is_admin)
            user = client.create_user(name)

        user_id = user["Id"]
        policy = client.get_user_policy(user_id)
        desired = desired_user_policy(policy, is_admin=is_admin)
        if policy != desired:
            LOG.info("PATCHing policy for '%s' (admin=%s)", name, is_admin)
            client.update_user_policy(user_id, desired)
        else:
            LOG.info("policy for '%s' already correct", name)

        # IMPORTANT: policy update must run BEFORE password reset.
        # If a user is currently admin in the DB, ResetPassword=true
        # would 400 (admin must have password). Demoting first lets
        # the reset succeed.
        if is_admin:
            pw = read_secret(settings.secrets_dir, f"password_{name}")
            client.set_user_password(user_id, pw)
        else:
            client.reset_user_password(user_id)


def desired_sso_config(settings: Settings, client_id: str, client_secret: str) -> dict:
    """Plugin config for POST /sso/OID/Add/<provider>.

    Field names match the OidConfig class in
    9p4/jellyfin-plugin-sso v4.0.0.4
    (https://github.com/9p4/jellyfin-plugin-sso/blob/v4.0.0.4/SSO-Auth/Config/PluginConfiguration.cs).

    Notes:
      - `EnableAuthorization = False` is critical. With it true, the
        plugin's `Authenticate` method runs role-based admin/folder
        permission updates on EVERY OIDC login: it calls
        `user.SetPermission(IsAdministrator, isAdmin)` where `isAdmin`
        is derived from the user's role claims vs `AdminRoles`. Empty
        `AdminRoles = []` means `isAdmin=false`, so every login DEMOTES
        the user to non-admin — overwriting whatever the seed Job's
        policy POST set. With `EnableAuthorization=false` the plugin
        skips that block, and admin status is governed solely by the
        seed Job's policy POST. Access control happens upstream at
        Zitadel via `has_project_check=true` on the project, which
        ensures only users with an explicit grant get tokens.
      - `NewPath = True` makes the plugin advertise
        `/sso/OID/redirect/<provider>` as the redirect URI consistently
        (the plugin alternates between `/redirect/` and `/r/` based on
        this flag). The Zitadel client is registered with the
        `/redirect/` form to match.
      - `SchemeOverride = "https"` forces the plugin's
        `GetRequestBase()` to use https when constructing the
        redirect_uri sent to the IdP. Jellyfin lives behind a
        TLS-terminating nginx sidecar, so it sees the request scheme
        as plain http — without this override the plugin would emit
        `http://jellyfin.<magic>/sso/OID/redirect/zitadel` which
        Zitadel rejects with "The requested redirect_uri is missing
        in the client configuration".
      - `DefaultProvider` does NOT cause the browser /web/index.html to
        auto-redirect to OIDC. It pins each authenticated user's
        AuthenticationProviderId post-login so the user is associated
        with the SSO plugin going forward. The "Login with Zitadel"
        button on the login page is what the user clicks to start the
        OIDC dance.
      - `OidScopes` does NOT include any Zitadel-specific aud-mapping
        scope. The plugin's audience validation tolerates extra entries
        in `aud` (default OWIN behaviour: the JWT must just contain the
        configured client_id). Zitadel's default `aud = [client_id,
        project_id]` is accepted unchanged.
      - The `OidConfig` class has no `NewUserPolicy` field — JIT-created
        users land with the SSO plugin's hardcoded defaults; we sidestep
        JIT entirely by pre-seeding local users matching
        `preferred_username`.
    """
    return {
        "OidEndpoint":             settings.oidc_issuer_url,
        "OidClientId":             client_id,
        "OidSecret":               client_secret,
        "Enabled":                 True,
        # MUST be false — see method docstring for the demote-on-login bug.
        "EnableAuthorization":     False,
        "EnableAllFolders":        True,
        "EnabledFolders":          [],
        "AdminRoles":              [],
        "Roles":                   [],
        "EnableFolderRoles":       False,
        "FolderRoleMapping":       [],
        "EnableLiveTv":            False,
        "EnableLiveTvManagement":  False,
        "OidScopes":               ["openid", "email", "profile"],
        "CanonicalLinks":          {},
        "RoleClaim":               "",
        "DefaultProvider":         settings.oidc_provider,
        "DefaultUsernameClaim":    "preferred_username",
        "NewPath":                 True,
        "DisableHttps":            False,
        "DoNotValidateEndpoints":  False,
        "DoNotValidateIssuerName": False,
        "SchemeOverride":          "https",
    }


def redact_sso(config: dict) -> dict:
    """Shallow copy with sensitive keys replaced by '<redacted>' for logs."""
    return {
        k: ("<redacted>" if k in SENSITIVE_SSO_KEYS else v)
        for k, v in config.items()
    }


def reconcile_sso_plugin(client: JellyfinClient, settings: Settings,
                         state: dict) -> None:
    """POST plugin config to /sso/OID/Add/<provider>. Hash-gated."""
    if not settings.oidc_issuer_url:
        LOG.info("OIDC_ISSUER_URL empty; skipping SSO plugin config")
        return

    client_id = read_secret(settings.secrets_dir, "oidc_client_id")
    client_secret = read_secret(settings.secrets_dir, "oidc_client_secret")

    desired = desired_sso_config(settings, client_id, client_secret)
    # Hash the rendered payload so a config-shape change (e.g. NewPath
    # default flip after a plugin upgrade) re-runs the POST.
    h = section_hash(desired)
    if section_cached(state, "sso_plugin", h):
        LOG.info("SSO plugin inputs unchanged (hash=%s); skipping", h[:12])
        return

    LOG.info("POST /sso/OID/Add/%s body=%s",
             settings.oidc_provider, redact_sso(desired))
    client.sso_set_provider(settings.oidc_provider, desired)
    record_section(state, "sso_plugin", h)
    save_seed_state(settings.seed_state_path, state)
    LOG.info("SSO plugin reconciled")


# --- Branding (login button injection) -------------------------------------

# Form HTML the 9p4 plugin README directs users to paste into the
# Branding "Login disclaimer" field. The form action URL must be the
# PUBLIC URL of Jellyfin (browser-side resolution), not the
# cluster-internal one.
_LOGIN_DISCLAIMER_TPL = """\
<form action="{public_url}/sso/OID/start/{provider}" method="get">
  <button class="raised block emby-button button-submit">{button_text}</button>
</form>"""

_LOGIN_DISCLAIMER_CSS = (
    "a.raised.emby-button { padding: 0.9em 1em; color: inherit !important; } "
    ".disclaimerContainer { display: block; }"
)


def desired_branding(settings: Settings, current: dict) -> dict:
    """Inject SSO button HTML + CSS while preserving any other branding
    fields (Splashscreen state, etc.) the operator may have set."""
    out = dict(current)
    out["LoginDisclaimer"] = _LOGIN_DISCLAIMER_TPL.format(
        public_url=settings.jellyfin_public_url.rstrip("/"),
        provider=settings.oidc_provider,
        button_text=settings.oidc_button_text,
    )
    out["CustomCss"] = _LOGIN_DISCLAIMER_CSS
    return out


def reconcile_branding(client: JellyfinClient, settings: Settings,
                        state: dict) -> None:
    """Inject the SSO login button via Jellyfin's BrandingOptions.

    The 9p4 SSO plugin doesn't auto-inject a button — its README directs
    users to paste a `<form action=".../sso/OID/start/<provider>">` HTML
    block into the Login disclaimer field, which Jellyfin then renders
    on the login page. We do that programmatically so the user-facing
    experience is correct on first apply.

    Hash-gated against the rendered desired state so unchanged inputs
    are a no-op."""
    current = client.get_branding()
    desired = desired_branding(settings, current)

    h = section_hash(desired.get("LoginDisclaimer"), desired.get("CustomCss"))
    if section_cached(state, "branding", h):
        LOG.info("branding inputs unchanged (hash=%s); skipping", h[:12])
        return

    if current == desired:
        LOG.info("branding already matches desired state; recording hash")
        record_section(state, "branding", h)
        save_seed_state(settings.seed_state_path, state)
        return

    LOG.info("PATCH /System/Configuration/branding (login-button HTML inject)")
    client.update_branding(desired)
    record_section(state, "branding", h)
    save_seed_state(settings.seed_state_path, state)


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="[%(name)s] %(message)s",
        stream=sys.stdout,
    )
    settings = Settings.from_env()
    LOG.info("Jellyfin seed: url=%s users=%s admins=%s",
             settings.jellyfin_url, settings.users, settings.admin_users)

    state = load_seed_state(settings.seed_state_path)
    if settings.seed_state_path.parts:
        LOG.info("seed-state cache at %s; sections cached: %s",
                 settings.seed_state_path,
                 sorted((state.get("sections") or {}).keys()) or "<none>")

    client = JellyfinClient(settings.jellyfin_url)
    try:
        reconcile_startup(client, settings)
        seed_user = login_seed(client, settings)
        reconcile_seed_admin(client, seed_user)
        reconcile_users(client, settings)
        # Quick Connect is default-on (ServerConfiguration.QuickConnectAvailable
        # = true in Jellyfin 10.10+) — no API call needed. The QuickConnect
        # controller routes are /Enabled, /Initiate, /Connect, /Authorize;
        # there's no /Activate. If a future operator disables it via the
        # dashboard, re-enable in the dashboard.
        reconcile_sso_plugin(client, settings, state)
        reconcile_branding(client, settings, state)
    except JellyfinError as e:
        die(str(e))
    except Exception as e:  # noqa: BLE001 — last-resort with traceback
        die(f"unexpected {type(e).__name__}: {e}", exc=e)

    LOG.info("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
