#!/usr/bin/env python3
"""Audiobookshelf bootstrap + reconcile.

Idempotent. Re-runs are safe — each step compares current state to desired
state and only acts on diffs. Vault is the source of truth for user
passwords and the JWT signing key (already wired through env-var-mounted
secrets).

API signatures (verified against advplyr/audiobookshelf master):
  GET  /status                  -> {isInit, serverVersion, ...}
  POST /init                    body {newRoot: {username, password}}
                                returns 200, no body
  POST /login                   body {username, password}
                                returns {user: {id, token, ...}}
  GET  /api/users               returns {users: [...]}
  POST /api/users               body {username, password, type?}
                                returns {user: {...}}
  PATCH /api/users/<id>         body {password} (server hashes to pash)
                                returns {success, user}
  GET  /api/libraries           returns {libraries: [{id, mediaType,
                                  libraryFolders: [{id, path/fullPath}]}]}
  POST /api/libraries           body {name, mediaType, folders:
                                  [{fullPath}]}
                                returns the created library
  POST /api/podcasts/opml/parse body {opmlText}
                                returns {feeds: [{title, feedUrl, ...}]}
                                (master renamed this to /api/podcasts/opml;
                                v2.34.0 still uses /opml/parse — keep this
                                path until the deployment image rolls past
                                that rename)
  POST /api/podcasts/opml/create body {feeds: [url], libraryId, folderId,
                                  autoDownloadEpisodes}
                                returns 200 (async server-side processing)
  GET  /api/libraries/<id>/items?limit=N
                                returns {results: [item, ...], total, ...}
  PATCH /api/items/<id>/media   body (flat) {autoDownloadEpisodes,
                                  autoDownloadSchedule, maxEpisodesToKeep,
                                  maxNewEpisodesToDownload, ...}
                                returns the updated item
  GET  /api/podcasts/<id>/checknew?limit=N
                                triggers an RSS re-fetch and downloads up to
                                N new episodes (relative to the item's
                                lastEpisodeCheck cursor). UI's "Check for
                                New Episodes" calls this.
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
import urllib.request
from pathlib import Path
from typing import Any, Optional

LOG = logging.getLogger("seed")

# Endpoints whose request body contains secrets — never log the body.
# /api/auth-settings carries the OIDC client_secret on a PATCH.
SENSITIVE_PATHS = ("/login", "/init", "/api/users", "/api/auth-settings")

# Keys in the ABS auth-settings JSON whose values must never appear in logs.
SENSITIVE_AUTH_KEYS = frozenset({"authOpenIDClientID", "authOpenIDClientSecret"})


@dataclasses.dataclass
class Settings:
    abs_url: str
    users: list[str]
    root_user: str
    secrets_dir: Path
    opml_path: Path
    podcasts_dir: str
    default_max_episodes: int
    default_schedule: str
    auto_download_podcasts: dict[str, dict]
    settings_wait_seconds: int
    initial_lookback_days: int
    fresh_import_window_seconds: int
    # Library-level "mark as finished" threshold. Maps to ABS's
    # library.settings.markAsFinishedPercentComplete (0-100). None = leave
    # ABS's default (time-remaining based) in place.
    mark_finished_percent: Optional[float]
    # OIDC. Empty oidc_issuer_url disables the reconcile step entirely so
    # the script can ship before TF wires Zitadel up.
    oidc_issuer_url: str
    oidc_match_email: str
    oidc_button_text: str
    oidc_mobile_redirect_uris: list[str]
    # Per-section hash cache. Lives on the ABS config PVC so a PVC wipe
    # invalidates it (correct: full re-seed needed). Empty path disables
    # caching, which is the correct behavior in tests + when the PVC isn't
    # mounted (older Job specs).
    seed_state_path: Path

    @classmethod
    def from_env(cls) -> "Settings":
        users_csv = os.environ.get("USERS", "").strip()
        users = [u.strip() for u in users_csv.split(",") if u.strip()]
        if not users:
            die("USERS env var is empty — at least one user required")

        auto_download_raw = os.environ.get("AUTO_DOWNLOAD_PODCASTS", "{}").strip() or "{}"
        try:
            auto_download = json.loads(auto_download_raw)
        except json.JSONDecodeError as e:
            die(f"AUTO_DOWNLOAD_PODCASTS is not valid JSON: {e}")
        if not isinstance(auto_download, dict):
            die(f"AUTO_DOWNLOAD_PODCASTS must be a JSON object, got {type(auto_download).__name__}")

        mobile_csv = os.environ.get(
            "OIDC_MOBILE_REDIRECT_URIS",
            "audiobookshelf://oauth,shelfplayer://callback",
        ).strip()
        mobile_uris = [u.strip() for u in mobile_csv.split(",") if u.strip()]

        return cls(
            abs_url=require_env("ABS_URL").rstrip("/"),
            users=users,
            root_user=os.environ.get("ROOT_USER") or users[0],
            secrets_dir=Path(os.environ.get("SECRETS_DIR", "/mnt/secrets")),
            opml_path=Path(os.environ.get("OPML_PATH", "/etc/abs-seed/podcasts.opml")),
            podcasts_dir=os.environ.get("PODCASTS_DIR", "/podcasts"),
            default_max_episodes=int(os.environ.get("PODCAST_DEFAULT_MAX_EPISODES", "0")),
            default_schedule=os.environ.get("PODCAST_DEFAULT_SCHEDULE", "0 */6 * * *"),
            auto_download_podcasts=auto_download,
            settings_wait_seconds=int(os.environ.get("PODCAST_SETTINGS_WAIT_SECONDS", "300")),
            initial_lookback_days=int(os.environ.get("PODCAST_INITIAL_LOOKBACK_DAYS", "7")),
            fresh_import_window_seconds=int(os.environ.get("PODCAST_FRESH_IMPORT_WINDOW_SECONDS", "21600")),
            mark_finished_percent=_parse_optional_float(os.environ.get("PODCAST_MARK_FINISHED_PERCENT", "")),
            oidc_issuer_url=os.environ.get("OIDC_ISSUER_URL", "").rstrip("/"),
            oidc_match_email=os.environ.get("OIDC_MATCH_EMAIL", "").strip(),
            oidc_button_text=os.environ.get("OIDC_BUTTON_TEXT", "Login with Zitadel"),
            oidc_mobile_redirect_uris=mobile_uris,
            seed_state_path=Path(os.environ.get("SEED_STATE_PATH", "")),
        )


class AbsError(RuntimeError):
    """API call failed in a way the script can't recover from."""


def require_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        die(f"{name} env var is required")
    return val


def _parse_optional_float(raw: str) -> Optional[float]:
    """Treat empty string / whitespace as None so an unset env var disables
    the corresponding setting entirely. Anything else must parse cleanly."""
    s = (raw or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        die(f"could not parse float from {raw!r}")
        return None  # unreachable; placates the type checker


def die(msg: str, exc: Optional[BaseException] = None) -> None:
    LOG.error(msg)
    if exc is not None and not isinstance(exc, AbsError):
        # Stack traces are safe — none of our exceptions carry passwords.
        # Sensitive-endpoint bodies are never logged in the first place.
        LOG.error("traceback:\n%s", "".join(traceback.format_exception(exc)))
    sys.exit(1)


def _is_transient_network_error(exc: urllib.error.URLError) -> bool:
    """Return True for errors that warrant a retry (connection-refused,
    reset, DNS, generic timeout). Excludes URLError shapes that imply a
    permanent issue (e.g. unsupported scheme) — there are none in the
    happy-path use of this client, but keep the matcher specific so a
    real bug doesn't silently spin."""
    reason = exc.reason
    # Wraps OSError / ConnectionError on most Python builds.
    if isinstance(reason, ConnectionError):
        return True
    if isinstance(reason, OSError):
        # errno 111 = ECONNREFUSED, 104 = ECONNRESET, 110 = ETIMEDOUT,
        # -2/-3 = DNS lookup failures (getaddrinfo), 113 = EHOSTUNREACH.
        if getattr(reason, "errno", None) in (111, 104, 110, 113, -2, -3):
            return True
    if isinstance(reason, TimeoutError):
        return True
    # Last-resort string match for builds that surface only the message.
    msg = str(reason).lower()
    return any(s in msg for s in (
        "connection refused", "connection reset", "name or service not known",
        "temporary failure in name resolution", "timed out", "no route to host",
    ))


def read_password(secrets_dir: Path, user: str) -> str:
    f = secrets_dir / f"password_{user}"
    if not f.is_file():
        raise AbsError(
            f"missing password file for user '{user}' at {f} — Vault CSI sync may have failed"
        )
    return f.read_text().rstrip("\n")


class AbsClient:
    # Reloader bouncing the ABS deployment (e.g. when OIDC creds first land
    # in the Vault-backed config secret) leaves the Service endpoint-less for
    # a few seconds; kube-proxy returns RST → "[Errno 111] Connection refused".
    # /status's retry loop hides the first bounce, but a second bounce mid-run
    # would otherwise abort. Treat connection-refused / reset / DNS as
    # transient on EVERY request.
    NETWORK_RETRIES = 8
    NETWORK_RETRY_BASE_DELAY_S = 1.0

    def __init__(self, base_url: str):
        self.base = base_url
        self.token: Optional[str] = None

    def _request(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        timeout: float = 30.0,
        expect_json: bool = True,
    ) -> Any:
        url = self.base + path
        sensitive = any(path.startswith(p) for p in SENSITIVE_PATHS)
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

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
                        raise AbsError(
                            f"{method} {path} returned non-JSON (status={resp.status}, "
                            f"content-type={resp.headers.get('Content-Type')!r}): "
                            f"{raw[:300]!r}"
                        ) from e
            except urllib.error.HTTPError as e:
                # 4xx/5xx are responses, not transport faults — never retried.
                err_body = e.read().decode("utf-8", errors="replace")[:500]
                raise AbsError(
                    f"{method} {path} -> HTTP {e.code} {e.reason}: {err_body!r}"
                ) from e
            except urllib.error.URLError as e:
                if not _is_transient_network_error(e) or attempt == self.NETWORK_RETRIES - 1:
                    raise AbsError(f"{method} {path} -> network error: {e.reason}") from e
                delay = self.NETWORK_RETRY_BASE_DELAY_S * (2 ** attempt)
                LOG.info("%s %s transient network error (%s); retry %d/%d in %.1fs",
                         method, path, e.reason, attempt + 1, self.NETWORK_RETRIES - 1, delay)
                time.sleep(delay)
                last_err = e

        # Defensive — loop above always returns or raises; this is unreachable.
        raise AbsError(f"{method} {path} -> exhausted retries: {last_err}")

    # --- High-level verbs --------------------------------------------------

    def wait_for_status(self, timeout_s: int = 300, interval_s: float = 5.0) -> dict:
        """Poll /status until 200. Returns parsed body."""
        deadline = time.monotonic() + timeout_s
        last_err: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                return self._request("GET", "/status", timeout=10)
            except AbsError as e:
                last_err = e
                LOG.info("ABS not ready yet (%s), retrying...", str(e).split(":", 1)[0])
                time.sleep(interval_s)
        raise AbsError(f"ABS /status never responded within {timeout_s}s; last error: {last_err}")

    def init_root(self, username: str, password: str) -> None:
        self._request(
            "POST", "/init", body={"newRoot": {"username": username, "password": password}},
            expect_json=False,
        )

    def login(self, username: str, password: str) -> dict:
        resp = self._request(
            "POST", "/login", body={"username": username, "password": password}
        )
        if not isinstance(resp, dict) or "user" not in resp:
            raise AbsError(f"unexpected /login response shape: keys={list(resp or [])}")
        user = resp["user"]
        token = user.get("token") or resp.get("token")
        if not token:
            raise AbsError("/login response missing token")
        self.token = token
        return user

    def list_users(self) -> list[dict]:
        resp = self._request("GET", "/api/users")
        if not isinstance(resp, dict) or "users" not in resp:
            raise AbsError(f"unexpected /api/users response shape: {resp!r}")
        return resp["users"]

    def create_user(self, username: str, password: str, user_type: str = "user") -> dict:
        resp = self._request(
            "POST", "/api/users",
            body={"username": username, "password": password, "type": user_type},
        )
        if not isinstance(resp, dict) or "user" not in resp:
            raise AbsError(f"unexpected POST /api/users response: {resp!r}")
        return resp["user"]

    def update_password(self, user_id: str, password: str) -> None:
        self._request("PATCH", f"/api/users/{user_id}", body={"password": password})

    def update_user_email(self, user_id: str, email: str) -> None:
        self._request("PATCH", f"/api/users/{user_id}", body={"email": email})

    def get_auth_settings(self) -> dict:
        resp = self._request("GET", "/api/auth-settings")
        if not isinstance(resp, dict):
            raise AbsError(f"unexpected /api/auth-settings response: {resp!r}")
        return resp

    def update_auth_settings(self, payload: dict) -> dict:
        resp = self._request("PATCH", "/api/auth-settings", body=payload)
        # PATCH returns the updated settings; tolerate empty for older builds.
        return resp if isinstance(resp, dict) else {}

    def discover_oidc_config(self, issuer: str) -> dict:
        # ABS itself proxies the issuer's discovery doc through this endpoint
        # — using it here avoids re-implementing the URL-shape detection (some
        # IdPs advertise endpoints under a /v2/ subpath) and keeps the seed
        # script's view of "what ABS sees" identical to the runtime view.
        from urllib.parse import quote
        resp = self._request("GET", f"/auth/openid/config?issuer={quote(issuer, safe='')}")
        if not isinstance(resp, dict) or "issuer" not in resp:
            raise AbsError(f"unexpected /auth/openid/config response: {resp!r}")
        return resp

    def list_libraries(self) -> list[dict]:
        resp = self._request("GET", "/api/libraries")
        if not isinstance(resp, dict) or "libraries" not in resp:
            raise AbsError(f"unexpected /api/libraries response: {resp!r}")
        return resp["libraries"]

    def create_library(self, name: str, media_type: str, full_path: str) -> dict:
        resp = self._request(
            "POST", "/api/libraries",
            body={"name": name, "mediaType": media_type,
                  "folders": [{"fullPath": full_path}]},
        )
        if not isinstance(resp, dict) or "id" not in resp:
            raise AbsError(f"unexpected POST /api/libraries response: {resp!r}")
        return resp

    def update_library(self, library_id: str, payload: dict) -> dict:
        # PATCH /api/libraries/<id> accepts any subset of top-level library
        # fields plus a nested `settings` object. We always pass settings
        # nested; the controller validates per-key types.
        resp = self._request("PATCH", f"/api/libraries/{library_id}", body=payload)
        if not isinstance(resp, dict):
            raise AbsError(f"unexpected PATCH /api/libraries/{library_id} response: {resp!r}")
        return resp

    def parse_opml(self, opml_text: str) -> list[dict]:
        # v2.34.0 path; master uses /api/podcasts/opml.
        path = "/api/podcasts/opml/parse"
        resp = self._request("POST", path, body={"opmlText": opml_text})
        if not isinstance(resp, dict) or "feeds" not in resp:
            raise AbsError(f"unexpected {path} response: {resp!r}")
        return resp["feeds"] or []

    def bulk_create_podcasts(
        self, feed_urls: list[str], library_id: str, folder_id: str,
        auto_download: bool = False,
    ) -> None:
        self._request(
            "POST", "/api/podcasts/opml/create",
            body={"feeds": feed_urls, "libraryId": library_id,
                  "folderId": folder_id, "autoDownloadEpisodes": auto_download},
            expect_json=False,
        )

    def list_library_items(self, library_id: str, limit: int = 10000) -> list[dict]:
        resp = self._request(
            "GET", f"/api/libraries/{library_id}/items?limit={limit}&minified=0"
        )
        if not isinstance(resp, dict) or "results" not in resp:
            raise AbsError(f"unexpected library-items response: {resp!r}")
        return resp["results"]

    def update_podcast_media(self, item_id: str, media_payload: dict) -> None:
        # PATCH /api/items/<id>/media expects a flat media object — fields
        # like autoDownloadEpisodes, autoDownloadSchedule, maxEpisodesToKeep
        # sit at the top level of the body (not nested under `media`).
        self._request("PATCH", f"/api/items/{item_id}/media", body=media_payload)

    def checknew_podcast(self, item_id: str, limit: int = 3) -> Any:
        """GET /api/podcasts/<id>/checknew?limit=N — what the UI's
        'Check for New Episodes' button calls. Triggers an RSS re-fetch
        and downloads up to N new episodes since lastEpisodeCheck."""
        return self._request(
            "GET", f"/api/podcasts/{item_id}/checknew?limit={limit}",
            timeout=60,
        )


# --- URL normalization for matching OPML/config URLs against ABS-stored ---


def norm_url(u: Optional[str]) -> str:
    """Canonical form for feed-URL comparison. Strips trailing slash, lowercases
    host (URL paths are case-sensitive on most hosts in theory, but in practice
    podcast hosts treat them case-insensitively). Coerces http→https."""
    if not u:
        return ""
    u = u.strip()
    if u.startswith("http://"):
        u = "https://" + u[len("http://"):]
    return u.rstrip("/").lower()


# --- Per-section hash cache -------------------------------------------------
#
# State file layout (lives on the audiobookshelf-config PVC):
#
#   {
#     "version": 1,
#     "sections": {
#       "<section>": {"hash": "<hex>", "applied_at": "<iso8601>"}
#     }
#   }
#
# Each reconcile step that's expensive computes a hash over its inputs and
# checks this file before running. Match -> skip + log. Mismatch -> run, then
# atomically rewrite the file with the new hash. PVC-co-location is deliberate:
# wiping the PVC also wipes the cache, forcing a full re-seed on a clean DB.

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
    """Return the parsed state dict, or a fresh empty one. Tolerant of a
    corrupt/missing file — a hash miss just forces the section to re-run.

    An empty Path (caching disabled) returns an empty state without
    touching the filesystem."""
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
    """Atomic write: tmpfile in same dir, fsync, rename. Skips silently
    when path is empty (caching disabled — Path("") has empty parts)."""
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
    """Returns True iff the persisted hash matches `current_hash`."""
    prev = (state.get("sections") or {}).get(section, {}).get("hash")
    return prev == current_hash


def record_section(state: dict, section: str, current_hash: str) -> None:
    """Update `state` in-place. Caller is responsible for save_seed_state."""
    state.setdefault("sections", {})[section] = {
        "hash": current_hash,
        "applied_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    state["version"] = STATE_VERSION


# --- Reconciliation steps --------------------------------------------------


def reconcile_root(client: AbsClient, settings: Settings) -> dict:
    """Ensure root user exists with the Vault-managed password."""
    status = client.wait_for_status()
    LOG.info("ABS up: version=%s isInit=%s",
             status.get("serverVersion"), status.get("isInit"))

    root_pw = read_password(settings.secrets_dir, settings.root_user)

    if not status.get("isInit"):
        LOG.info("running POST /init for root user '%s'", settings.root_user)
        client.init_root(settings.root_user, root_pw)
    else:
        LOG.info("ABS already initialised, skipping /init")

    LOG.info("logging in as '%s'", settings.root_user)
    user = client.login(settings.root_user, root_pw)
    LOG.info("root login OK (id=%s, type=%s)", user["id"], user.get("type"))

    # Vault is source of truth — re-PATCH on every run so a TF
    # `-replace=random_password.audiobookshelf_user_passwords[...]` cycle
    # propagates without manual intervention.
    LOG.info("reconciling root password from Vault")
    client.update_password(user["id"], root_pw)
    return user


def reconcile_oidc(client: AbsClient, settings: Settings, root_user: dict,
                    state: dict) -> None:
    """Reconcile ABS server-settings OIDC config with Zitadel.

    No-op when OIDC_ISSUER_URL is empty. Otherwise:
      1. Ensure the local root user's email matches OIDC_MATCH_EMAIL so
         ABS's `matchExistingBy: "email"` links the Zitadel sub to the
         existing account on first SSO login (preserving listening
         progress / per-user state).
      2. Ask ABS to discover the issuer's endpoints (avoids reimplementing
         IdP-specific URL shapes here).
      3. Diff desired vs current /api/auth-settings; PATCH only the keys
         that drift. No-op on a steady-state re-run.

    Sensitive values (client_id/secret) are never logged.

    Gated by a per-section hash so we don't even talk to Zitadel when
    inputs haven't changed since the last successful run.
    """
    if not settings.oidc_issuer_url:
        LOG.info("OIDC_ISSUER_URL empty, skipping OIDC reconcile")
        return

    client_id_path = settings.secrets_dir / "oidc_client_id"
    client_secret_path = settings.secrets_dir / "oidc_client_secret"
    if not client_id_path.is_file() or not client_secret_path.is_file():
        raise AbsError(
            f"OIDC creds missing at {client_id_path} / {client_secret_path} — "
            "Vault CSI sync may have failed"
        )
    client_id = client_id_path.read_text().rstrip("\n")
    client_secret = client_secret_path.read_text().rstrip("\n")

    # Hash inputs that drive the desired payload. Includes credentials so a
    # rotation forces a re-PATCH; the hash itself is one-way and safe to
    # persist alongside non-secret state.
    h = section_hash(
        settings.oidc_issuer_url,
        client_id,
        client_secret,
        settings.oidc_button_text,
        settings.oidc_match_email,
        sorted(settings.oidc_mobile_redirect_uris),
    )
    if section_cached(state, "oidc", h):
        LOG.info("OIDC inputs unchanged (hash=%s); skipping reconcile", h[:12])
        return

    if settings.oidc_match_email:
        # /login response carries the full user object incl. email — no
        # second GET needed (ABS doesn't expose GET /api/users/<id> at all
        # on some builds, returning connection-refused instead of 404).
        current_email = (root_user.get("email") or "").strip()
        if current_email != settings.oidc_match_email:
            LOG.info("setting root user email -> %s for OIDC email-match",
                     settings.oidc_match_email)
            client.update_user_email(root_user["id"], settings.oidc_match_email)
        else:
            LOG.info("root user email already matches OIDC_MATCH_EMAIL")

    LOG.info("discovering OIDC endpoints for issuer=%s", settings.oidc_issuer_url)
    discovery = client.discover_oidc_config(settings.oidc_issuer_url)

    desired: dict[str, Any] = {
        "authOpenIDIssuerURL":             discovery["issuer"],
        "authOpenIDAuthorizationURL":      discovery["authorization_endpoint"],
        "authOpenIDTokenURL":              discovery["token_endpoint"],
        "authOpenIDUserInfoURL":           discovery["userinfo_endpoint"],
        "authOpenIDJwksURL":               discovery["jwks_uri"],
        "authOpenIDLogoutURL":             discovery.get("end_session_endpoint", ""),
        "authOpenIDClientID":              client_id,
        "authOpenIDClientSecret":          client_secret,
        "authOpenIDTokenSigningAlgorithm": "RS256",
        "authOpenIDButtonText":            settings.oidc_button_text,
        "authOpenIDAutoLaunch":            True,
        "authOpenIDAutoRegister":          False,
        "authOpenIDMatchExistingBy":       "email",
        "authOpenIDMobileRedirectURIs":    list(settings.oidc_mobile_redirect_uris),
        # ABS concatenates this directly into the redirect_uri it sends to
        # the IdP. When unset in the DB, some builds emit the literal string
        # "undefined" (JS coerces `undefined`→string), giving redirect URIs
        # like /undefined/auth/openid/callback that don't match what's
        # registered in Zitadel. Force "" so the URI is the bare path.
        "authOpenIDSubfolderForRedirectURLs": "",
        # ABS sorts this alphabetically before persisting (see MiscController
        # validation) — sort here so the diff is stable.
        "authActiveAuthMethods":           sorted(["local", "openid"]),
    }

    current = client.get_auth_settings()
    diff = {k: v for k, v in desired.items() if current.get(k) != v}
    if not diff:
        LOG.info("OIDC server-settings already in sync; no PATCH needed")
        record_section(state, "oidc", h)
        save_seed_state(settings.seed_state_path, state)
        return

    safe_keys = sorted(k for k in diff if k not in SENSITIVE_AUTH_KEYS)
    sensitive_keys = sorted(k for k in diff if k in SENSITIVE_AUTH_KEYS)
    LOG.info("PATCH /api/auth-settings: drift in %s%s",
             safe_keys,
             f" + sensitive {sensitive_keys}" if sensitive_keys else "")
    client.update_auth_settings(diff)
    record_section(state, "oidc", h)
    save_seed_state(settings.seed_state_path, state)
    LOG.info("OIDC server-settings reconciled")


def reconcile_users(client: AbsClient, settings: Settings) -> None:
    """Create non-root users from var.audiobookshelf_users; reconcile passwords."""
    existing = {u["username"]: u for u in client.list_users()}
    LOG.info("existing users: %s", sorted(existing.keys()))

    for username in settings.users:
        if username == settings.root_user:
            continue
        try:
            pw = read_password(settings.secrets_dir, username)
        except AbsError as e:
            LOG.warning("skipping user '%s': %s", username, e)
            continue
        if username in existing:
            LOG.info("user '%s' exists; reconciling password from Vault", username)
            client.update_password(existing[username]["id"], pw)
        else:
            LOG.info("creating user '%s'", username)
            client.create_user(username, pw, user_type="user")


def get_or_create_podcast_library(client: AbsClient, settings: Settings) -> tuple[str, str]:
    """Return (library_id, folder_id), creating both if absent."""
    libs = client.list_libraries()
    lib = next((l for l in libs if l.get("mediaType") == "podcast"), None)
    if lib is None:
        LOG.info("creating Podcasts library at %s", settings.podcasts_dir)
        client.create_library("Podcasts", "podcast", settings.podcasts_dir)
        # Re-fetch — the create response shape varies, this is the canonical
        # source of folder IDs.
        libs = client.list_libraries()
        lib = next((l for l in libs if l.get("mediaType") == "podcast"), None)
        if lib is None:
            raise AbsError("podcast library missing after create — apply may be partial")

    lib_id = lib.get("id")
    # ABS responses use either `folders` (old JSON shape) or `libraryFolders`
    # (newer). Tolerate both.
    folders = lib.get("folders") or lib.get("libraryFolders") or []
    if not folders:
        raise AbsError(f"podcast library {lib_id} has no folders configured")
    folder_id = folders[0].get("id")
    if not lib_id or not folder_id:
        raise AbsError(
            f"podcast library object missing id/folder.id: lib_id={lib_id!r} folder={folders[0]!r}"
        )
    LOG.info("podcast library: id=%s folder=%s path=%s",
             lib_id, folder_id, folders[0].get("fullPath") or folders[0].get("path"))
    return lib_id, folder_id


def reconcile_library_settings(client: AbsClient, settings: Settings,
                                library_id: str, state: dict) -> None:
    """Apply library-level settings (currently `markAsFinishedPercentComplete`)
    to the Podcasts library. Hash-gated so unchanged inputs are a no-op.

    ABS exposes `markAsFinishedPercentComplete` (0-100, null disables in
    favor of `markAsFinishedTimeRemaining`). When set, ABS marks an episode
    finished as soon as playback crosses that percentage. We always send the
    value as a number (or null) — the master controller accepts either.
    """
    desired_pct = settings.mark_finished_percent

    h = section_hash(desired_pct)
    if section_cached(state, "library_settings", h):
        LOG.info("library-settings inputs unchanged (hash=%s); skipping", h[:12])
        return

    libs = client.list_libraries()
    lib = next((l for l in libs if l.get("id") == library_id), None)
    if lib is None:
        raise AbsError(f"library {library_id} vanished between create and settings PATCH")
    current = (lib.get("settings") or {}).get("markAsFinishedPercentComplete", None)

    if current == desired_pct:
        LOG.info("markAsFinishedPercentComplete already %s; no PATCH needed", current)
        record_section(state, "library_settings", h)
        save_seed_state(settings.seed_state_path, state)
        return

    LOG.info("PATCH library settings: markAsFinishedPercentComplete %s -> %s",
             current, desired_pct)
    client.update_library(library_id, {"settings": {"markAsFinishedPercentComplete": desired_pct}})
    record_section(state, "library_settings", h)
    save_seed_state(settings.seed_state_path, state)


def reconcile_opml(client: AbsClient, settings: Settings,
                   library_id: str, folder_id: str, state: dict) -> None:
    """Submit only NEW OPML feeds for bulk creation.

    ABS's bulk-create endpoint doesn't filter on its own — it iterates every
    URL and logs `Podcast already exists` for dupes. To stay quiet on no-op
    re-runs we diff parsed-OPML against currently-present feedUrls in the
    library and only submit the ones ABS hasn't ingested yet.

    Gated by a per-section hash on the OPML text so an unchanged file
    skips the parse + library-walk entirely.
    """
    if not settings.opml_path.is_file():
        LOG.info("no OPML file at %s, skipping podcast import", settings.opml_path)
        return
    opml_text = settings.opml_path.read_text().strip()
    if not opml_text:
        LOG.info("OPML at %s is empty, skipping podcast import", settings.opml_path)
        return

    h = section_hash(opml_text)
    if section_cached(state, "opml", h):
        LOG.info("OPML unchanged (hash=%s); skipping import", h[:12])
        return

    LOG.info("parsing OPML at %s (%d bytes)", settings.opml_path, len(opml_text))
    feeds = client.parse_opml(opml_text)
    parsed_urls = [f["feedUrl"] for f in feeds if f.get("feedUrl")]
    if not parsed_urls:
        LOG.warning("OPML parsed but yielded no feed URLs (raw count=%d)", len(feeds))
        return

    items = client.list_library_items(library_id)
    existing_urls = {
        norm_url((item.get("media") or {}).get("metadata", {}).get("feedUrl"))
        for item in items
    }
    existing_urls.discard("")

    new_urls = [u for u in parsed_urls if norm_url(u) not in existing_urls]
    skipped = len(parsed_urls) - len(new_urls)
    if skipped:
        LOG.info("skipping %d feed(s) already present in library", skipped)

    if not new_urls:
        LOG.info("all %d OPML feeds already imported; nothing to submit", len(parsed_urls))
        record_section(state, "opml", h)
        save_seed_state(settings.seed_state_path, state)
        return

    LOG.info("submitting %d new feed(s) to /api/podcasts/opml/create (async)", len(new_urls))
    client.bulk_create_podcasts(new_urls, library_id, folder_id, auto_download=False)
    LOG.info("bulk-create accepted; ABS will fetch + create podcasts in the background")
    record_section(state, "opml", h)
    save_seed_state(settings.seed_state_path, state)


def desired_media_payload(feed_url: str, settings: Settings, item: dict) -> dict:
    """Build the PATCH /api/items/<id>/media body for one podcast.

    TF's optional() emits unset fields as JSON null (Python None); .get()
    returns None for present-but-null keys, so we cannot rely on its default
    arg — pull the value first and `if x is None` -fall back to settings.

    `lastEpisodeCheck` (the cursor that drives scheduled auto-download) is
    only rewound for FRESHLY-IMPORTED podcasts. ABS itself advances the
    cursor on each poll; rewinding mid-life would re-fetch episodes that
    maxEpisodesToKeep already deleted, so we gate on item.addedAt being
    within settings.fresh_import_window_seconds of now.
    """
    media = item.get("media") or {}
    auto = settings.auto_download_podcasts
    override = next((auto[k] for k in auto if norm_url(k) == norm_url(feed_url)), {}) or {}

    # Default policy: every podcast auto-downloads on the default schedule.
    # An entry in `auto_download_podcasts` is an OVERRIDE — set
    # `auto_download = false` there to opt a specific feed out.
    auto_download_override = override.get("auto_download")
    auto_download = True if auto_download_override is None else bool(auto_download_override)

    max_keep = override.get("max_episodes_to_keep")
    if max_keep is None:
        max_keep = settings.default_max_episodes

    payload: dict[str, Any] = {
        "autoDownloadEpisodes": auto_download,
        "maxEpisodesToKeep": int(max_keep),
    }
    if auto_download:
        sched = override.get("schedule") or settings.default_schedule
        payload["autoDownloadSchedule"] = sched

    max_new = override.get("max_new_episodes_to_download")
    if max_new is not None:
        payload["maxNewEpisodesToDownload"] = int(max_new)

    # Lookback seeding is ONLY for auto-download podcasts. ABS's /checknew
    # endpoint downloads new episodes regardless of autoDownloadEpisodes,
    # so rewinding the cursor on a non-auto-download (opt-out) podcast would
    # either do nothing (if /checknew is never called manually) or trigger
    # an unwanted ~week of downloads (if it is). Now that auto-download is
    # ON by default, this gate skips only the explicitly opted-out feeds.
    added_at_ms = item.get("addedAt") or 0
    age_s = (time.time() * 1000 - added_at_ms) / 1000
    if (auto_download
            and settings.initial_lookback_days > 0
            and added_at_ms > 0
            and age_s < settings.fresh_import_window_seconds):
        ms = int((time.time() - settings.initial_lookback_days * 86400) * 1000)
        payload["lastEpisodeCheck"] = ms

    return payload


def reconcile_podcast_settings(client: AbsClient, settings: Settings,
                                library_id: str, state: dict) -> None:
    """Apply maxEpisodesToKeep + autoDownload settings to every podcast item.

    OPML bulk-create is async — items appear gradually as ABS fetches each
    feed. This function polls the library, PATCHes any item it hasn't
    configured yet, and exits early when every podcast in the user's
    auto-download list has been configured. Stragglers (slow-fetching feeds)
    get picked up on the next apply since the loop is idempotent.

    Gated by a per-section hash. The hash includes the OPML hash so that
    a freshly-imported podcast always re-runs this step (ABS items lag
    OPML submission by several seconds).
    """
    opml_hash = (state.get("sections") or {}).get("opml", {}).get("hash", "")
    h = section_hash(
        settings.default_max_episodes,
        settings.default_schedule,
        sorted(settings.auto_download_podcasts.items()),
        settings.initial_lookback_days,
        settings.fresh_import_window_seconds,
        # Cache-bust whenever the OPML import changed — newly-fetched items
        # can't be configured by a stale cache entry.
        opml_hash,
    )
    if section_cached(state, "podcast_settings", h):
        LOG.info("podcast-settings inputs unchanged (hash=%s); skipping", h[:12])
        return

    # Wait-for-import gate: feeds explicitly listed in auto_download_podcasts
    # are user-flagged as "I care about these," so we keep retrying until they
    # appear in the library. Other OPML feeds get configured opportunistically
    # each iteration; stragglers settle on the next apply.
    expected_present = {norm_url(u) for u in settings.auto_download_podcasts}
    LOG.info("reconciling podcast settings: default_max=%d, default auto-download=ON, %d explicitly-listed feeds awaited",
             settings.default_max_episodes, len(expected_present))

    deadline = time.monotonic() + settings.settings_wait_seconds
    configured: set[str] = set()  # normalized feedUrls we've PATCHed
    seeded: list[tuple[str, str]] = []  # (item_id, feed_url) where lookback was rewound
    iteration = 0
    completed_cleanly = False  # only the success-break path flips this

    while True:
        iteration += 1
        items = client.list_library_items(library_id)
        present_urls: set[str] = set()
        new_this_iter = 0
        for item in items:
            media = item.get("media") or {}
            feed_url = media.get("metadata", {}).get("feedUrl")
            if not feed_url:
                continue
            n = norm_url(feed_url)
            present_urls.add(n)
            if n in configured:
                continue
            payload = desired_media_payload(feed_url, settings, item)
            try:
                client.update_podcast_media(item["id"], payload)
                configured.add(n)
                new_this_iter += 1
                seeded_cursor = "lastEpisodeCheck" in payload
                if seeded_cursor:
                    seeded.append((item["id"], feed_url))
                LOG.info("  configured %s (autoDownload=%s, maxKeep=%s%s)",
                         feed_url, payload["autoDownloadEpisodes"], payload["maxEpisodesToKeep"],
                         f", seeded lookback {settings.initial_lookback_days}d" if seeded_cursor else "")
            except AbsError as e:
                LOG.warning("  failed to PATCH %s (id=%s): %s", feed_url, item.get("id"), e)

        missing = expected_present - present_urls
        LOG.info("iteration %d: %d items in library, %d configured this run, %d listed feeds still missing",
                 iteration, len(items), new_this_iter, len(missing))

        if not missing:
            LOG.info("all explicitly-listed podcasts configured")
            completed_cleanly = True
            break
        if time.monotonic() >= deadline:
            LOG.warning("timeout reached with %d listed feeds still missing — re-run TF apply once ABS finishes background fetches",
                        len(missing))
            for u in sorted(missing):
                LOG.warning("  not yet present: %s", u)
            break
        time.sleep(15)

    # Trigger an immediate check-new for podcasts where we just rewound the
    # cursor. ABS would otherwise wait until the next scheduled poll (up to
    # autoDownloadSchedule's interval) before fetching the past-week episodes.
    # Bounded to seeded items so we don't spam ABS on routine re-applies.
    if seeded:
        LOG.info("triggering /checknew for %d freshly-seeded podcast(s) (limit=3 episodes each)", len(seeded))
        for item_id, feed_url in seeded:
            try:
                client.checknew_podcast(item_id, limit=3)
                LOG.info("  checknew %s OK", feed_url)
            except AbsError as e:
                LOG.warning("  checknew %s failed: %s", feed_url, e)

    # Only persist the cache if every expected feed was configured. A
    # timeout-with-stragglers leaves the hash unchanged so the next run
    # picks up where this one left off.
    if completed_cleanly:
        record_section(state, "podcast_settings", h)
        save_seed_state(settings.seed_state_path, state)


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="[%(name)s] %(message)s",
        stream=sys.stdout,
    )
    settings = Settings.from_env()
    LOG.info("ABS seed: url=%s users=%s root=%s",
             settings.abs_url, settings.users, settings.root_user)

    state = load_seed_state(settings.seed_state_path)
    if settings.seed_state_path.parts:
        LOG.info("seed-state cache at %s; sections cached: %s",
                 settings.seed_state_path,
                 sorted((state.get("sections") or {}).keys()) or "<none>")

    client = AbsClient(settings.abs_url)
    try:
        root_user = reconcile_root(client, settings)
        reconcile_users(client, settings)
        reconcile_oidc(client, settings, root_user, state)
        lib_id, folder_id = get_or_create_podcast_library(client, settings)
        reconcile_library_settings(client, settings, lib_id, state)
        reconcile_opml(client, settings, lib_id, folder_id, state)
        reconcile_podcast_settings(client, settings, lib_id, state)
    except AbsError as e:
        die(str(e))
    except Exception as e:  # noqa: BLE001 — last-resort catch with traceback
        die(f"unexpected {type(e).__name__}: {e}", exc=e)

    LOG.info("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
