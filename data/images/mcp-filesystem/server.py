"""Filesystem MCP server, sandboxed per-API-key and per-session.

Every tool call takes a `session_id` string. Operations are pinned under
`$MCP_DATA_ROOT/<hash(api_key+salt)>/<hash(session_id+salt)>`. Path escapes
via `..` or symlinks are rejected via realpath prefix check.

Environment:
  MCP_API_KEYS   CSV of accepted Bearer tokens. Empty/unset is fail-closed
                 (every request is rejected — no anonymous access).
  MCP_PATH_SALT  Hex or base64 salt mixed into tenant/session hashes.
  MCP_DATA_ROOT  Backing directory (default /data).
  MCP_HOST       Bind host (default 0.0.0.0)
  MCP_PORT       Bind port (default 8000)
  MCP_MAX_FILE_BYTES  Per-file byte ceiling for read/write/edit (default 10 MiB).
  MCP_MAX_READ_BATCH  Max paths per `read_multiple_files` call (default 32).
  MCP_MAX_EDITS       Max edits per `edit_file` call (default 64).
  MCP_MAX_EDIT_BYTES  Per-edit oldText/newText byte ceiling (default 256 KiB).
  MCP_MAX_TENANT_BYTES        Per-tenant total disk quota (default 1 GiB).
  MCP_MAX_SESSIONS_PER_TENANT Session count cap per tenant (default 256).
  MCP_MAX_DIR_ENTRIES         list_directory per-dir cap (default 2000).
  MCP_MAX_TREE_DEPTH          directory_tree recursion cap (default 32).
  MCP_MAX_TREE_NODES          directory_tree total-node cap (default 5000).
  MCP_MAX_SEARCH_HITS         search_files hit cap (default 2000).
  MCP_MAX_SESSION_ID_CHARS    session_id length cap (default 128).
  LOG_LEVEL      debug / info / warning / error (default info).

Tool set mirrors @modelcontextprotocol/server-filesystem with a mandatory
`session_id` prefix argument; `edit_file` is a line-for-line port of the
upstream algorithm.
"""

import difflib
import fnmatch
import json
import os
import pathlib
import re
import secrets
import shutil
from typing import TypedDict

from fastmcp import FastMCP

from mcp_common import (
    bootstrap,
    current_api_key,
    env_csv_set,
    env_int,
    hash_tenant,
    init_tenant_root,
    setup_logging,
)

API_KEYS = env_csv_set("MCP_API_KEYS")
PATH_SALT, DATA_ROOT = init_tenant_root()
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = env_int("MCP_PORT", "8000")
MCP_MAX_FILE_BYTES = env_int("MCP_MAX_FILE_BYTES", str(10 * 1024 * 1024))
MCP_MAX_READ_BATCH = env_int("MCP_MAX_READ_BATCH", "32")
MCP_MAX_EDITS = env_int("MCP_MAX_EDITS", "64")
MCP_MAX_EDIT_BYTES = env_int("MCP_MAX_EDIT_BYTES", str(256 * 1024))
MCP_MAX_DESCRIPTION_CHARS = env_int("MCP_MAX_DESCRIPTION_CHARS", "1024")
MCP_MAX_TENANT_BYTES = env_int("MCP_MAX_TENANT_BYTES", str(1 * 1024 * 1024 * 1024))
MCP_MAX_SESSIONS_PER_TENANT = env_int("MCP_MAX_SESSIONS_PER_TENANT", "256")
MCP_MAX_DIR_ENTRIES = env_int("MCP_MAX_DIR_ENTRIES", "2000")
MCP_MAX_TREE_DEPTH = env_int("MCP_MAX_TREE_DEPTH", "32")
MCP_MAX_TREE_NODES = env_int("MCP_MAX_TREE_NODES", "5000")
MCP_MAX_SEARCH_HITS = env_int("MCP_MAX_SEARCH_HITS", "2000")
MCP_MAX_SESSION_ID_CHARS = env_int("MCP_MAX_SESSION_ID_CHARS", "128")

_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._\-]+$")

log = setup_logging("mcp-filesystem")
log.info("startup: data_root=%s api_keys=%d", DATA_ROOT, len(API_KEYS))


class EditOp(TypedDict):
    """One edit for `edit_file`: replace `oldText` with `newText`."""

    oldText: str
    newText: str

_INSTRUCTIONS = """\
Per-tenant sandboxed filesystem. Every tool takes a `session_id` string.

SESSION_ID — pick a stable name per task (e.g. "bug-42", "scratch-notes")
and REUSE IT across tool calls so files accumulate in one namespace.
Different session_ids get different, isolated sandboxes; do NOT send a
random UUID per call or your files will scatter. Allowed chars:
[A-Za-z0-9._-], max MCP_MAX_SESSION_ID_CHARS (default 128).

Typical workflow:
  1. `list_sessions` to see existing namespaces for this tenant.
  2. Reuse an existing session_id, or pick a new one.
  3. Optional: `describe_session` to tag it with a human label.
  4. Use `read_file` / `write_file` / `edit_file` / `list_directory` / etc.

Sandbox rules:
  - Paths are relative to the session root. `..` escapes are rejected.
  - Absolute paths like `/foo.txt` are treated as session-root-relative.
  - UTF-8 text only; binary reads will error.
  - Symlinks surface in listings (type="symlink") but every op refuses them.

Caps: per-file size, listing length, tree depth, search hits, tenant disk
quota, session count. When a listing/tree/search is truncated you will see
a trailing sentinel entry `{"name":"...", "type":"truncated"}` — narrow
the path or pattern to see more.

DESTRUCTIVE: `destroy_session` wipes every file in the session. Only call
when the user explicitly asks to wipe it.
"""

# FastMCP v2: transport (host/port/path) is configured at run/http_app time,
# not on the constructor. Constructor takes only the server name + options.
mcp = FastMCP("filesystem", instructions=_INSTRUCTIONS)


def _hash(v: str) -> str:
    # Thin wrapper so existing call sites stay short. Identical algorithm to
    # mcp-memory's hashing (both servers share the `mcp_data` PVC and must
    # land at the same per-tenant subdir).
    return hash_tenant(PATH_SALT, v)


def _tenant_dir() -> pathlib.Path:
    """Per-API-key directory. Requires an api key bound to the contextvar."""
    key = current_api_key.get()
    if not key:
        log.error("tenant_dir: no api key in request context")
        raise PermissionError("no api key in request context")
    return DATA_ROOT / _hash(key)


def _sessions_file() -> pathlib.Path:
    return _tenant_dir() / "sessions.json"


def _load_sessions() -> list[dict]:
    f = _sessions_file()
    if not f.exists():
        return []
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError) as e:
        log.error("sessions.json unreadable (%s), treating as empty", e)
        return []


def _save_sessions(sessions: list[dict]) -> None:
    f = _sessions_file()
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f"{f.name}.{secrets.token_hex(8)}.tmp")
    try:
        tmp.write_text(json.dumps(sessions, indent=2), encoding="utf-8")
        os.replace(tmp, f)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def _upsert_session(session_id: str, description: str | None = None) -> None:
    """Append a new session entry or update an existing one's description."""
    sessions = _load_sessions()
    for s in sessions:
        if s.get("session_id") == session_id:
            if description is not None:
                s["description"] = description
                _save_sessions(sessions)
            return
    sessions.append({"session_id": session_id, "description": description or ""})
    _save_sessions(sessions)


def _remove_session_from_index(session_id: str) -> None:
    sessions = _load_sessions()
    pruned = [s for s in sessions if s.get("session_id") != session_id]
    if len(pruned) != len(sessions):
        _save_sessions(pruned)


def _session_root_path(session_id: str) -> pathlib.Path:
    """Pure: compute the session root path without touching the filesystem."""
    if not session_id or not session_id.strip():
        raise ValueError("session_id required")
    if len(session_id) > MCP_MAX_SESSION_ID_CHARS:
        raise ValueError(
            f"session_id too long ({len(session_id)} > MCP_MAX_SESSION_ID_CHARS={MCP_MAX_SESSION_ID_CHARS})",
        )
    if not _SESSION_ID_RE.match(session_id):
        raise ValueError("session_id must match [A-Za-z0-9._-]+ (no spaces or other chars)")
    key = current_api_key.get()
    if not key:
        log.error("session_root: no api key in request context")
        raise PermissionError("no api key in request context")
    return DATA_ROOT / _hash(key) / _hash(session_id)


def _session_root(session_id: str, *, mkdir: bool = True) -> pathlib.Path:
    """Resolve the session root. Creates it unless `mkdir=False`.

    When creating, enforces MCP_MAX_SESSIONS_PER_TENANT against the tenant's
    index. A session_id already in the index is not counted as a new session,
    so no-op re-opens never trip the cap.
    """
    root = _session_root_path(session_id)
    if not mkdir:
        return root.resolve() if root.exists() else root
    existed = root.exists()
    if not existed:
        sessions = _load_sessions()
        already_indexed = any(s.get("session_id") == session_id for s in sessions)
        if not already_indexed and len(sessions) >= MCP_MAX_SESSIONS_PER_TENANT:
            raise ValueError(
                f"session count exceeded: {len(sessions)} >= "
                f"MCP_MAX_SESSIONS_PER_TENANT={MCP_MAX_SESSIONS_PER_TENANT}",
            )
    root.mkdir(parents=True, exist_ok=True)
    if not existed:
        log.info("session_root created: %s", root)
        _upsert_session(session_id)
    else:
        log.debug("session_root: %s", root)
    return root.resolve()


def _tenant_usage() -> int:
    """Sum of all file sizes under the caller's tenant dir. Symlinks skipped.

    Excludes the per-tenant `sessions.json` index — it is server metadata,
    not user content, and would otherwise eat into the tenant's quota
    purely as a function of how many sessions they've named.

    O(n) walk — called on every write/edit. Acceptable for homelab scale;
    swap for a cached counter if tenant trees grow large.
    """
    root = _tenant_dir()
    if not root.exists():
        return 0
    sessions_index = _sessions_file()
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            fp = pathlib.Path(dirpath) / name
            if fp == sessions_index:
                continue
            try:
                if fp.is_symlink():
                    continue
                total += fp.stat(follow_symlinks=False).st_size
            except OSError:
                # Vanished between walk and stat — just skip.
                continue
    return total


def _check_tenant_quota(new_bytes: int, replaced_bytes: int = 0) -> None:
    """Reject if writing new_bytes (replacing replaced_bytes of existing file) would exceed quota."""
    current = _tenant_usage()
    projected = current - replaced_bytes + new_bytes
    if projected > MCP_MAX_TENANT_BYTES:
        raise ValueError(
            f"tenant disk quota exceeded: projected {projected} > "
            f"MCP_MAX_TENANT_BYTES={MCP_MAX_TENANT_BYTES}",
        )


def _safe(session_id: str, user_path: str, *, must_exist: bool = False) -> pathlib.Path:
    """Resolve a caller-supplied path inside the session root.

    Absolute-looking paths are treated as session-root-relative (leading
    slashes stripped). `resolve()` collapses `..` and follows existing
    symlinks; escape is rejected before any fs mutation.
    """
    root = _session_root(session_id)
    rel = (user_path or ".").lstrip("/")
    real = (root / rel).resolve()

    if not (real == root or _is_within(real, root)):
        log.error("path escape: session=%s user_path=%r real=%s", session_id, user_path, real)
        raise PermissionError(f"path escapes session root: {user_path}")

    if not real.exists():
        if must_exist:
            log.debug("safe: missing %r (must_exist)", user_path)
            raise FileNotFoundError(user_path)
        # Only now, after validation, is it safe to create the parent chain.
        real.parent.mkdir(parents=True, exist_ok=True)
        log.debug("safe: %r -> %s (new)", user_path, real)
    else:
        log.debug("safe: %r -> %s", user_path, real)
    return real


def _is_within(child: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        child.relative_to(root)
        return True
    except ValueError:
        return False


def _reject_symlink(p: pathlib.Path) -> None:
    # _safe validates by realpath, but operating *on* a symlink (even one
    # whose target is inside the sandbox) is still surprising and blocks
    # TOCTOU swaps if a future tool ever lets a tenant create one.
    if p.is_symlink():
        raise PermissionError(f"refusing to operate on symlink: {p.name}")


def _display(path: pathlib.Path, session_id: str) -> str:
    """Re-expose a resolved path as session-root-relative. Pure (no fs side effects)."""
    try:
        root = _session_root_path(session_id).resolve()
    except (ValueError, PermissionError):
        return str(path)
    try:
        rel = path.resolve().relative_to(root)
    except ValueError:
        return str(path)
    s = str(rel)
    return "/" if s == "." else f"/{s}"


def _normalize_line_endings(text: str) -> str:
    return text.replace("\r\n", "\n")


@mcp.tool()
async def read_file(session_id: str, path: str) -> str:
    """Read a UTF-8 text file within the session root."""
    p = _safe(session_id, path, must_exist=True)
    _reject_symlink(p)
    size = p.stat().st_size
    if size > MCP_MAX_FILE_BYTES:
        raise ValueError(f"file exceeds MCP_MAX_FILE_BYTES ({size} > {MCP_MAX_FILE_BYTES})")
    data = p.read_text(encoding="utf-8")
    log.info("read_file: %s (%d bytes)", p, len(data))
    return data


@mcp.tool()
async def read_multiple_files(session_id: str, paths: list[str]) -> dict[str, dict]:
    """Read several files in one call.

    Returns `{path: {"ok": True, "content": "..."}}` on success and
    `{path: {"ok": False, "error": "ExcType: message"}}` on failure, so
    callers can distinguish errors from file content that happens to look
    like an error string. The batch length is capped by MCP_MAX_READ_BATCH
    and per-file size by MCP_MAX_FILE_BYTES.
    """
    if len(paths) > MCP_MAX_READ_BATCH:
        raise ValueError(f"too many paths ({len(paths)} > MCP_MAX_READ_BATCH={MCP_MAX_READ_BATCH})")
    out: dict[str, dict] = {}
    failures = 0
    for rel in paths:
        try:
            p = _safe(session_id, rel, must_exist=True)
            _reject_symlink(p)
            size = p.stat().st_size
            if size > MCP_MAX_FILE_BYTES:
                raise ValueError(f"file exceeds MCP_MAX_FILE_BYTES ({size} > {MCP_MAX_FILE_BYTES})")
            out[rel] = {"ok": True, "content": p.read_text(encoding="utf-8")}
        except Exception as e:
            failures += 1
            log.warning("read_multiple_files: %r failed: %s", rel, e)
            out[rel] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    log.info("read_multiple_files: %d paths, %d failures", len(paths), failures)
    return out


@mcp.tool()
async def write_file(session_id: str, path: str, content: str) -> dict:
    """Write content to a file, creating parent dirs as needed. Capped by MCP_MAX_FILE_BYTES.

    Enforces the tenant-wide MCP_MAX_TENANT_BYTES quota (replacement size
    offset against the existing file, if any).
    """
    n = len(content.encode("utf-8"))
    if n > MCP_MAX_FILE_BYTES:
        raise ValueError(f"content exceeds MCP_MAX_FILE_BYTES ({n} > {MCP_MAX_FILE_BYTES})")
    p = _safe(session_id, path)
    replaced = 0
    if p.exists():
        _reject_symlink(p)
        try:
            replaced = p.stat(follow_symlinks=False).st_size
        except OSError:
            replaced = 0
    _check_tenant_quota(n, replaced)
    tmp = p.with_name(f"{p.name}.{secrets.token_hex(8)}.tmp")
    try:
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, p)
    except Exception as e:
        log.error("write_file failed: %s: %s", p, e)
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    log.info("write_file: %s (%d bytes)", p, n)
    return {"path": _display(p, session_id), "bytes": n}


@mcp.tool()
async def edit_file(
    session_id: str,
    path: str,
    edits: list[EditOp],
    dry_run: bool = False,
) -> str:
    """Apply sequential `{oldText, newText}` line edits to a text file.

    Each edit must match exactly (or line-by-line with normalized whitespace;
    original indent is preserved). Returns a git-style unified diff. If
    dry_run is true, the file is not modified.
    """
    if len(edits) > MCP_MAX_EDITS:
        raise ValueError(f"too many edits ({len(edits)} > MCP_MAX_EDITS={MCP_MAX_EDITS})")
    for i, e in enumerate(edits):
        for field in ("oldText", "newText"):
            n = len(e.get(field, "").encode("utf-8"))
            if n > MCP_MAX_EDIT_BYTES:
                raise ValueError(
                    f"edits[{i}].{field} exceeds MCP_MAX_EDIT_BYTES ({n} > {MCP_MAX_EDIT_BYTES})",
                )
    p = _safe(session_id, path, must_exist=True)
    _reject_symlink(p)
    size = p.stat().st_size
    if size > MCP_MAX_FILE_BYTES:
        raise ValueError(f"file exceeds MCP_MAX_FILE_BYTES ({size} > {MCP_MAX_FILE_BYTES})")
    # newline="" disables universal-newline translation so we can detect CRLF.
    with p.open(encoding="utf-8", newline="") as f:
        raw = f.read()
    had_crlf = "\r\n" in raw
    original = _normalize_line_endings(raw)
    modified = original
    log.debug("edit_file: %s (%d edits, dry_run=%s)", p, len(edits), dry_run)

    for edit in edits:
        old = _normalize_line_endings(edit.get("oldText", ""))
        new = _normalize_line_endings(edit.get("newText", ""))

        if old in modified:
            modified = modified.replace(old, new, 1)
            continue

        old_lines = old.split("\n")
        content_lines = modified.split("\n")
        matched = False
        for i in range(len(content_lines) - len(old_lines) + 1):
            window = content_lines[i : i + len(old_lines)]
            if all(ol.strip() == cl.strip() for ol, cl in zip(old_lines, window)):
                original_indent = re.match(r"^\s*", content_lines[i]).group(0)
                new_src = new.split("\n")
                rebuilt: list[str] = []
                for j, line in enumerate(new_src):
                    if j == 0:
                        rebuilt.append(original_indent + line.lstrip())
                    else:
                        old_indent = re.match(r"^\s*", old_lines[j]).group(0) if j < len(old_lines) else ""
                        new_indent = re.match(r"^\s*", line).group(0)
                        if old_indent and new_indent:
                            rel = max(0, len(new_indent) - len(old_indent))
                            rebuilt.append(original_indent + (" " * rel) + line.lstrip())
                        else:
                            rebuilt.append(line)
                content_lines[i : i + len(old_lines)] = rebuilt
                modified = "\n".join(content_lines)
                matched = True
                break
        if not matched:
            log.warning("edit_file: no match for edit in %s", p)
            raise ValueError(f"Could not find exact match for edit:\n{edit.get('oldText', '')}")

    diff_lines = list(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            modified.splitlines(keepends=True),
            fromfile=_display(p, session_id),
            tofile=_display(p, session_id),
            n=3,
        ),
    )
    diff = "".join(diff_lines)

    fence = "```"
    while fence in diff:
        fence += "`"
    formatted = f"{fence}diff\n{diff}{fence}\n\n"

    out = modified.replace("\n", "\r\n") if had_crlf else modified
    out_bytes = len(out.encode("utf-8"))
    if out_bytes > MCP_MAX_FILE_BYTES:
        raise ValueError(f"edited content exceeds MCP_MAX_FILE_BYTES ({out_bytes} > {MCP_MAX_FILE_BYTES})")

    if not dry_run:
        _check_tenant_quota(out_bytes, size)
        tmp = p.with_name(f"{p.name}.{secrets.token_hex(8)}.tmp")
        try:
            # newline="" skips os.linesep translation so CRLF survives as-is.
            with tmp.open("w", encoding="utf-8", newline="") as f:
                f.write(out)
            os.replace(tmp, p)
        except Exception as e:
            log.error("edit_file write failed: %s: %s", p, e)
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            raise
        log.info("edit_file: %s (%d edits applied)", p, len(edits))
    else:
        log.info("edit_file: %s (%d edits, dry_run)", p, len(edits))

    return formatted


@mcp.tool()
async def create_directory(session_id: str, path: str) -> dict:
    """Create a directory (and parents) inside the session root."""
    p = _safe(session_id, path)
    p.mkdir(parents=True, exist_ok=True)
    log.info("create_directory: %s", p)
    return {"path": _display(p, session_id)}


def _entry_type(child: pathlib.Path) -> str:
    # Symlinks surface as their own type so callers can see they exist;
    # any per-op tool will refuse them via _reject_symlink. The two
    # behaviors are deliberately paired so the LLM's mental model (listing
    # shows a "symlink" → operating on it errors) stays consistent.
    if child.is_symlink():
        return "symlink"
    return "dir" if child.is_dir(follow_symlinks=False) else "file"


@mcp.tool()
async def list_directory(session_id: str, path: str = ".") -> list[dict]:
    """List entries. Returns name + type (file/dir/symlink). Symlinks can't be operated on.

    Capped at MCP_MAX_DIR_ENTRIES; past the cap a trailing
    {"name": "...", "type": "truncated"} sentinel is appended.
    """
    p = _safe(session_id, path, must_exist=True)
    if not p.is_dir():
        raise NotADirectoryError(path)
    names: list[str] = []
    truncated = False
    with os.scandir(p) as it:
        for entry in it:
            if len(names) >= MCP_MAX_DIR_ENTRIES:
                truncated = True
                break
            names.append(entry.name)
    names.sort()
    entries = [{"name": n, "type": _entry_type(p / n)} for n in names]
    if truncated:
        entries.append({"name": "...", "type": "truncated"})
        log.warning("list_directory: truncated at %d for %s", MCP_MAX_DIR_ENTRIES, p)
    log.info("list_directory: %s (%d entries, truncated=%s)", p, len(entries), truncated)
    return entries


@mcp.tool()
async def directory_tree(session_id: str, path: str = ".") -> list[dict]:
    """Recursive nested listing. Symlinks appear as type=symlink and are not followed.

    Bounded by MCP_MAX_TREE_DEPTH (per-branch depth), MCP_MAX_TREE_NODES
    (total nodes visited), and MCP_MAX_DIR_ENTRIES (per-directory). On
    truncation a sibling/child `{"name":"...", "type":"truncated"}` entry
    is emitted so the LLM can see the listing was incomplete.
    """
    p = _safe(session_id, path, must_exist=True)
    if not p.is_dir():
        raise NotADirectoryError(path)

    counter = [0]  # total-node budget shared across recursion

    def walk(d: pathlib.Path, depth: int) -> list[dict]:
        if counter[0] >= MCP_MAX_TREE_NODES:
            return [{"name": "...", "type": "truncated"}]
        names: list[str] = []
        per_dir_truncated = False
        try:
            with os.scandir(d) as it:
                for entry in it:
                    if len(names) >= MCP_MAX_DIR_ENTRIES:
                        per_dir_truncated = True
                        break
                    names.append(entry.name)
        except OSError:
            return []
        names.sort()
        nodes: list[dict] = []
        for name in names:
            if counter[0] >= MCP_MAX_TREE_NODES:
                nodes.append({"name": "...", "type": "truncated"})
                return nodes
            counter[0] += 1
            child = d / name
            t = _entry_type(child)
            if t == "dir":
                if depth >= MCP_MAX_TREE_DEPTH:
                    nodes.append({
                        "name": name, "type": "dir",
                        "children": [{"name": "...", "type": "truncated"}],
                    })
                else:
                    nodes.append({"name": name, "type": "dir", "children": walk(child, depth + 1)})
            else:
                nodes.append({"name": name, "type": t})
        if per_dir_truncated:
            nodes.append({"name": "...", "type": "truncated"})
        return nodes

    tree = walk(p, 0)
    log.info("directory_tree: %s (%d nodes total)", p, counter[0])
    return tree


@mcp.tool()
async def move_file(
    session_id: str,
    source: str,
    destination: str,
    overwrite: bool = False,
) -> dict:
    """Move/rename a file or directory within the session root.

    By default refuses to clobber an existing `destination`. Pass
    `overwrite=True` to replace it.
    """
    src = _safe(session_id, source, must_exist=True)
    _reject_symlink(src)
    dst = _safe(session_id, destination)
    if dst.exists():
        _reject_symlink(dst)
        if not overwrite:
            raise FileExistsError(f"destination exists (pass overwrite=True to replace): {destination}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(dst))
    log.info("move_file: %s -> %s (overwrite=%s)", src, dst, overwrite)
    return {"source": _display(src, session_id), "destination": _display(dst, session_id)}


@mcp.tool()
async def search_files(
    session_id: str,
    pattern: str,
    path: str = ".",
    exclude_patterns: list[str] | None = None,
) -> list[str]:
    """Recursively search for names matching `pattern` (glob). Excludes are globs applied to names.

    Capped at MCP_MAX_SEARCH_HITS; past the cap a trailing
    "... (truncated at N)" sentinel string is appended so the LLM knows
    to narrow the pattern.
    """
    excludes = exclude_patterns or []
    root = _safe(session_id, path, must_exist=True)
    if not root.is_dir():
        raise NotADirectoryError(path)
    hits: list[str] = []
    truncated = False
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # Drop symlinked subdirs from recursion *and* from the listing below,
        # matching list_directory/directory_tree semantics.
        dirnames[:] = [
            d for d in dirnames
            if not (pathlib.Path(dirpath) / d).is_symlink()
            and not any(fnmatch.fnmatch(d, g) for g in excludes)
        ]
        for name in dirnames + filenames:
            if any(fnmatch.fnmatch(name, g) for g in excludes):
                continue
            full = pathlib.Path(dirpath) / name
            if full.is_symlink():
                continue
            if fnmatch.fnmatch(name, pattern):
                hits.append(_display(full, session_id))
                if len(hits) >= MCP_MAX_SEARCH_HITS:
                    truncated = True
                    break
        if truncated:
            break
    hits.sort()
    if truncated:
        hits.append(f"... (truncated at {MCP_MAX_SEARCH_HITS})")
        log.warning("search_files: truncated at %d for %s", MCP_MAX_SEARCH_HITS, root)
    log.info("search_files: root=%s pattern=%r hits=%d truncated=%s", root, pattern, len(hits), truncated)
    return hits


@mcp.tool()
async def get_file_info(session_id: str, path: str) -> dict:
    """Stat info for a path within the session root. Symlinks are refused."""
    p = _safe(session_id, path, must_exist=True)
    _reject_symlink(p)
    st = p.stat(follow_symlinks=False)
    return {
        "path": _display(p, session_id),
        # `type` matches list_directory / directory_tree vocabulary ("file"/"dir").
        # symlinks are refused above, so this is always file or dir here.
        "type": "dir" if p.is_dir(follow_symlinks=False) else "file",
        "size": st.st_size,
        "mtime": st.st_mtime,
        "ctime": st.st_ctime,
        "mode": oct(st.st_mode),
    }


@mcp.tool()
async def list_allowed_directories(session_id: str) -> list[str]:
    """Return the visible roots for this session. Always `["/"]` — the session root."""
    # Validate auth + session_id shape without creating the session dir.
    _session_root(session_id, mkdir=False)
    return ["/"]


@mcp.tool()
async def destroy_session(session_id: str) -> dict:
    """Delete every file and directory in this session's root. Irreversible.

    Scoped to the caller's tenant (api key) and the given session_id, so one
    caller cannot wipe another tenant's or another session's data.
    """
    root = _session_root(session_id, mkdir=False)
    if not root.exists():
        log.info("destroy_session: %s (no-op, did not exist)", root)
        _remove_session_from_index(session_id)
        return {"session_id": session_id, "removed": False}
    shutil.rmtree(root)
    _remove_session_from_index(session_id)
    log.warning("destroy_session: %s removed", root)
    return {"session_id": session_id, "removed": True}


@mcp.tool()
async def list_sessions() -> list[dict]:
    """Return every session known to this tenant.

    Each entry has `session_id` (the caller-supplied plaintext identifier) and
    `description` (set via `describe_session`, empty by default).
    """
    # Validate auth without creating anything.
    _tenant_dir()
    sessions = _load_sessions()
    log.info("list_sessions: %d entries", len(sessions))
    return sessions


@mcp.tool()
async def describe_session(session_id: str, description: str) -> dict:
    """Set a human-readable description for a session.

    Creates the session if it doesn't exist yet (same as any other tool that
    touches the session root). Descriptions are capped at
    `MCP_MAX_DESCRIPTION_CHARS` (default 1024).
    """
    if len(description) > MCP_MAX_DESCRIPTION_CHARS:
        raise ValueError(
            f"description exceeds {MCP_MAX_DESCRIPTION_CHARS} chars "
            f"(got {len(description)})",
        )
    # Ensure the session is registered in the index.
    _session_root(session_id)
    _upsert_session(session_id, description)
    log.info("describe_session: %s -> %r", session_id, description)
    return {"session_id": session_id, "description": description}


# Built at module load so the live-ASGI tests in test_server.py can mount
# the same app under uvicorn without re-running bootstrap.run().
app = bootstrap.build_app(mcp, api_keys=API_KEYS, logger=log)


if __name__ == "__main__":
    bootstrap.run_app(app, host=MCP_HOST, port=MCP_PORT)
