#!/usr/bin/env python3
"""Provision OpenObserve dashboards, alerts, destinations, templates.

Reads JSON artifacts from $CONFIG_DIR/{dashboards,destinations,templates,alerts}
and upserts them via the OpenObserve HTTP API. Idempotent: safe to re-run.

Env:
  OO_URL    Base URL, e.g. http://openobserve.monitoring.svc.cluster.local:5080
  OO_ORG    Org slug, typically "default"
  OO_AUTH   Base64 "email:password" for basic auth (ZO_ROOT_USER_*)
  CONFIG_DIR  Root dir holding the subdirs above

Exits 0 on full success, 1 if any artifact failed (excluding soft-skipped
alerts whose target stream doesn't exist yet — those retry on next apply).
"""

from __future__ import annotations

import base64
import json
import os
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OO_URL = os.environ["OO_URL"].rstrip("/")
OO_ORG = os.environ["OO_ORG"]
OO_AUTH = os.environ["OO_AUTH"]
CONFIG_DIR = Path(os.environ["CONFIG_DIR"])

HEADERS = {
    "Authorization": f"Basic {OO_AUTH}",
    "Content-Type": "application/json",
}


def derive_ntfy_basic_b64() -> None:
    """Compute NTFY_BASIC_B64 from NTFY_USER + NTFY_PASSWORD env, populate
    os.environ. Destination JSON templates reference $${NTFY_BASIC_B64} as a
    literal placeholder that load_jsons() expands at runtime, so the
    base64'd credential never lands in the ConfigMap on disk.
    """
    user = os.environ.get("NTFY_USER")
    password = os.environ.get("NTFY_PASSWORD")
    if user and password:
        os.environ["NTFY_BASIC_B64"] = base64.b64encode(
            f"{user}:{password}".encode()
        ).decode()


def request(method: str, path: str, body: dict | None = None) -> tuple[int, dict | list | None]:
    url = f"{OO_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            body = json.loads(raw) if raw else None
        except Exception:
            body = {"raw": raw.decode(errors="replace")}
        return e.code, body


def wait_ready(max_wait: int = 180) -> None:
    deadline = time.time() + max_wait
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{OO_URL}/healthz", timeout=5) as r:
                if r.status == 200:
                    print(f"openobserve ready at {OO_URL}")
                    return
        except Exception as e:
            print(f"waiting for openobserve: {e}")
        time.sleep(3)
    print(f"timed out waiting for {OO_URL}/healthz", file=sys.stderr)
    sys.exit(1)


def load_jsons(subdir: str, substitute_env: bool = False) -> list[tuple[str, dict]]:
    d = CONFIG_DIR / subdir
    if not d.is_dir():
        return []
    out = []
    for p in sorted(d.glob("*.json")):
        try:
            raw = p.read_text()
            if substitute_env:
                raw = string.Template(raw).safe_substitute(os.environ)
            out.append((p.stem, json.loads(raw)))
        except Exception as e:
            print(f"ERROR parsing {p}: {e}", file=sys.stderr)
            raise
    return out


def _extract_dashboard_list(body: dict | list | None) -> list[dict]:
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for key in ("dashboards", "data", "list"):
            val = body.get(key)
            if isinstance(val, list):
                return val
    return []


def _get_field(entry: dict, *keys: str) -> str | None:
    for key in keys:
        if isinstance(entry.get(key), str) and entry[key]:
            return entry[key]
    for version_key in ("v5", "v4", "v3", "v2", "v1", "v8", "v7", "v6"):
        nested = entry.get(version_key)
        if isinstance(nested, dict):
            for key in keys:
                if isinstance(nested.get(key), str) and nested[key]:
                    return nested[key]
    return None


def upsert_dashboard(name: str, body: dict) -> bool:
    """Match by `title`; PUT to the first existing (with required hash +
    folder query params), DELETE the rest, POST if none exist.
    """
    title = body.get("title")
    if not title:
        print(f"dashboard {name}: missing title", file=sys.stderr)
        return False

    # OO's list API supports title filter; ask for exact-title matches across
    # all folders so we dedup aggressively.
    q_title = urllib.parse.quote(title)
    status, listing = request("GET", f"/api/{OO_ORG}/dashboards?title={q_title}")
    if status != 200:
        print(f"dashboard {name}: list failed {status} {listing}", file=sys.stderr)
        return False

    # Filter to exact (case-sensitive) title matches since the API does
    # case-insensitive substring matching.
    matches = [
        e for e in _extract_dashboard_list(listing)
        if _get_field(e, "title") == title and _get_field(e, "dashboard_id", "dashboardId")
    ]

    if not matches:
        status, resp = request("POST", f"/api/{OO_ORG}/dashboards", body)
        if 200 <= status < 300:
            print(f"dashboard {name}: created")
            return True
        print(f"dashboard {name}: create failed {status} {resp}", file=sys.stderr)
        return False

    # Keep first, delete the rest.
    keep = matches[0]
    keep_id = _get_field(keep, "dashboard_id", "dashboardId")
    keep_hash = _get_field(keep, "hash")
    keep_folder = _get_field(keep, "folder_id", "folder") or "default"

    if not keep_hash:
        print(f"dashboard {name}: existing entry missing hash, cannot update", file=sys.stderr)
        return False

    put_path = (
        f"/api/{OO_ORG}/dashboards/{keep_id}"
        f"?folder={urllib.parse.quote(keep_folder)}"
        f"&hash={urllib.parse.quote(keep_hash)}"
    )
    status, resp = request("PUT", put_path, body)
    if not (200 <= status < 300):
        print(f"dashboard {name}: update failed {status} {resp}", file=sys.stderr)
        return False

    deleted = 0
    for dup in matches[1:]:
        dup_id = _get_field(dup, "dashboard_id", "dashboardId")
        dup_folder = _get_field(dup, "folder_id", "folder") or "default"
        del_path = f"/api/{OO_ORG}/dashboards/{dup_id}?folder={urllib.parse.quote(dup_folder)}"
        dstatus, dresp = request("DELETE", del_path)
        if 200 <= dstatus < 300 or dstatus == 404:
            deleted += 1
        else:
            print(f"dashboard {name}: delete-dup {dup_id} failed {dstatus} {dresp}", file=sys.stderr)

    if deleted:
        print(f"dashboard {name}: updated ({keep_id}), deduped {deleted} duplicate(s)")
    else:
        print(f"dashboard {name}: updated ({keep_id})")
    return True


def upsert_named(kind: str, name: str, body: dict, collection_path: str) -> bool:
    """PUT /{collection}/{name} if it exists, POST /{collection} otherwise.

    Used for destinations + templates where the object's own `name` is the
    stable identifier and the API supports PUT at the named path.
    """
    obj_name = body.get("name")
    if not obj_name:
        print(f"{kind} {name}: body missing 'name'", file=sys.stderr)
        return False
    status, _ = request("GET", f"{collection_path}/{obj_name}")
    if status == 200:
        status, resp = request("PUT", f"{collection_path}/{obj_name}", body)
        if 200 <= status < 300:
            print(f"{kind} {name}: updated")
            return True
    elif status == 404:
        status, resp = request("POST", collection_path, body)
        if 200 <= status < 300:
            print(f"{kind} {name}: created")
            return True
    print(f"{kind} {name}: {status} {resp}", file=sys.stderr)
    return False


def upsert_alert(name: str, body: dict) -> tuple[bool, bool]:
    """Returns (ok, skipped). skipped=True means the alert's target stream
    doesn't exist yet — treated as a soft failure (warning, not error)."""
    alert_name = body.get("name")
    if not alert_name:
        print(f"alert {name}: missing 'name'", file=sys.stderr)
        return False, False
    status, existing = request("GET", f"/api/v2/{OO_ORG}/alerts")
    found_id = None
    if status == 200 and isinstance(existing, dict):
        for item in existing.get("list", []) or []:
            if item.get("name") == alert_name:
                found_id = item.get("alert_id") or item.get("id")
                break
    elif status == 200 and isinstance(existing, list):
        for item in existing:
            if item.get("name") == alert_name:
                found_id = item.get("alert_id") or item.get("id")
                break
    if found_id:
        status, resp = request("PUT", f"/api/v2/{OO_ORG}/alerts/{found_id}", body)
        if 200 <= status < 300:
            print(f"alert {name}: updated ({found_id})")
            return True, False
    else:
        status, resp = request("POST", f"/api/v2/{OO_ORG}/alerts", body)
        if 200 <= status < 300:
            print(f"alert {name}: created")
            return True, False

    # Soft-skip if the alert references a stream that doesn't exist yet.
    # The stream gets created lazily on first ingest; re-running the Job
    # once logs are flowing will create the alert.
    msg = ""
    if isinstance(resp, dict):
        msg = str(resp.get("message", "")).lower()
    if status == 404 and "stream" in msg and "not found" in msg:
        print(f"alert {name}: SKIPPED — stream not yet ingested ({resp})")
        return False, True

    print(f"alert {name}: {status} {resp}", file=sys.stderr)
    return False, False


def main() -> int:
    wait_ready()
    derive_ntfy_basic_b64()
    failures = 0
    skipped = 0

    for name, body in load_jsons("templates"):
        ok = upsert_named(
            "template", name, body,
            collection_path=f"/api/{OO_ORG}/alerts/templates",
        )
        failures += 0 if ok else 1

    for name, body in load_jsons("destinations", substitute_env=True):
        ok = upsert_named(
            "destination", name, body,
            collection_path=f"/api/{OO_ORG}/alerts/destinations",
        )
        failures += 0 if ok else 1

    for name, body in load_jsons("dashboards"):
        failures += 0 if upsert_dashboard(name, body) else 1

    for name, body in load_jsons("alerts"):
        ok, was_skipped = upsert_alert(name, body)
        if was_skipped:
            skipped += 1
        elif not ok:
            failures += 1

    if skipped:
        print(f"{skipped} alert(s) soft-skipped — re-run once stream data flows")
    if failures:
        print(f"{failures} artifact(s) failed", file=sys.stderr)
        return 1
    print("all artifacts applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
