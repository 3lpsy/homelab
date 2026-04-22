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
  MCP_MAX_EDIT_BYTES  Per-edit oldText/newText byte ceiling (default 10 MiB).
  LOG_LEVEL      debug / info / warning / error (default info).

Tool set mirrors @modelcontextprotocol/server-filesystem with a mandatory
`session_id` prefix argument; `edit_file` is a line-for-line port of the
upstream algorithm.
"""

import contextvars
import difflib
import fnmatch
import hashlib
import json
import logging
import os
import pathlib
import re
import secrets
import shutil
from typing import TypedDict

import uvicorn
from fastmcp import FastMCP
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
PATH_SALT = os.environ.get("MCP_PATH_SALT", "").encode()
DATA_ROOT = pathlib.Path(os.environ.get("MCP_DATA_ROOT", "/data")).resolve()
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))
MCP_MAX_FILE_BYTES = int(os.environ.get("MCP_MAX_FILE_BYTES", str(10 * 1024 * 1024)))
MCP_MAX_READ_BATCH = int(os.environ.get("MCP_MAX_READ_BATCH", "32"))
MCP_MAX_EDITS = int(os.environ.get("MCP_MAX_EDITS", "64"))
MCP_MAX_EDIT_BYTES = int(os.environ.get("MCP_MAX_EDIT_BYTES", str(10 * 1024 * 1024)))
MCP_MAX_DESCRIPTION_CHARS = int(os.environ.get("MCP_MAX_DESCRIPTION_CHARS", "1024"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.ERROR),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("mcp-filesystem")

if not PATH_SALT:
    raise SystemExit("MCP_PATH_SALT must be set")

DATA_ROOT.mkdir(parents=True, exist_ok=True)
log.info("startup: data_root=%s api_keys=%d log_level=%s", DATA_ROOT, len(API_KEYS), LOG_LEVEL)

_api_key_ctx: contextvars.ContextVar[str] = contextvars.ContextVar("api_key", default="")


class EditOp(TypedDict):
    """One edit for `edit_file`: replace `oldText` with `newText`."""

    oldText: str
    newText: str

# FastMCP v2: transport (host/port/path) is configured at run/http_app time,
# not on the constructor. Constructor takes only the server name + options.
mcp = FastMCP("filesystem")


def _hash(v: str) -> str:
    # 128-bit truncation: collision risk is birthday ~2^64, fine for a
    # salted directory name. Not a credential hash.
    return hashlib.sha256(PATH_SALT + v.encode()).hexdigest()[:32]


def _tenant_dir() -> pathlib.Path:
    """Per-API-key directory. Requires an api key bound to the contextvar."""
    key = _api_key_ctx.get()
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
    key = _api_key_ctx.get()
    if not key:
        log.error("session_root: no api key in request context")
        raise PermissionError("no api key in request context")
    return DATA_ROOT / _hash(key) / _hash(session_id)


def _session_root(session_id: str, *, mkdir: bool = True) -> pathlib.Path:
    """Resolve the session root. Creates it unless `mkdir=False`."""
    root = _session_root_path(session_id)
    if not mkdir:
        return root.resolve() if root.exists() else root
    existed = root.exists()
    root.mkdir(parents=True, exist_ok=True)
    if not existed:
        log.info("session_root created: %s", root)
        _upsert_session(session_id)
    else:
        log.debug("session_root: %s", root)
    return root.resolve()


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
    """Write content to a file, creating parent dirs as needed. Capped by MCP_MAX_FILE_BYTES."""
    n = len(content.encode("utf-8"))
    if n > MCP_MAX_FILE_BYTES:
        raise ValueError(f"content exceeds MCP_MAX_FILE_BYTES ({n} > {MCP_MAX_FILE_BYTES})")
    p = _safe(session_id, path)
    if p.exists():
        _reject_symlink(p)
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
    """List entries. Returns name + type (file/dir/symlink). Symlinks can't be operated on."""
    p = _safe(session_id, path, must_exist=True)
    if not p.is_dir():
        raise NotADirectoryError(path)
    entries = [{"name": c.name, "type": _entry_type(c)} for c in sorted(p.iterdir())]
    log.info("list_directory: %s (%d entries)", p, len(entries))
    return entries


@mcp.tool()
async def directory_tree(session_id: str, path: str = ".") -> list[dict]:
    """Recursive nested listing. Symlinks appear as type=symlink and are not followed."""
    p = _safe(session_id, path, must_exist=True)
    if not p.is_dir():
        raise NotADirectoryError(path)

    def walk(d: pathlib.Path) -> list[dict]:
        nodes: list[dict] = []
        for child in sorted(d.iterdir()):
            t = _entry_type(child)
            if t == "dir":
                nodes.append({"name": child.name, "type": "dir", "children": walk(child)})
            else:
                nodes.append({"name": child.name, "type": t})
        return nodes

    tree = walk(p)
    log.info("directory_tree: %s (%d top-level entries)", p, len(tree))
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
    """Recursively search for names matching `pattern` (glob). Excludes are globs applied to names."""
    excludes = exclude_patterns or []
    root = _safe(session_id, path, must_exist=True)
    if not root.is_dir():
        raise NotADirectoryError(path)
    hits: list[str] = []
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
    log.info("search_files: root=%s pattern=%r hits=%d", root, pattern, len(hits))
    return sorted(hits)


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


# Pure ASGI middleware (not BaseHTTPMiddleware): BaseHTTPMiddleware runs the
# downstream app in a separate anyio task, and contextvars set in `dispatch`
# do not reliably propagate to the handler task. Running as raw ASGI keeps the
# whole request in one task, so `_api_key_ctx.set()` is visible to tools.
class AuthMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # ASGI startup/shutdown events must reach the inner app untouched.
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return

        # Everything that isn't HTTP is rejected closed — MCP streamable-http
        # does not use websockets, so a ws upgrade here is either a stray route
        # or an attacker probing for an auth bypass.
        if scope["type"] != "http":
            log.warning("auth: rejecting non-http scope: %s", scope["type"])
            if scope["type"] == "websocket":
                # ASGI spec: respond to websocket.connect with close (no accept).
                await receive()
                await send({"type": "websocket.close", "code": 1008})
            return

        # CORS preflight: no auth, no context.
        method = scope["method"]
        if method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        # Extract bearer token, falling back to ?api_key= query param.
        headers = Headers(scope=scope)
        header = headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not token:
            token = QueryParams(scope["query_string"]).get("api_key", "").strip()

        # Reject unknown or missing tokens. Empty API_KEYS also rejects (fail-closed).
        # compare_digest per candidate avoids per-byte timing leaks on the match.
        ok = bool(token) and any(secrets.compare_digest(token, k) for k in API_KEYS)
        if not ok:
            client = scope.get("client")
            log.warning(
                "auth: rejected %s %r from %s",
                method, scope["path"], client[0] if client else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return

        # Bind token into contextvar for this request; reset on the way out so
        # the value does not leak if the underlying task is reused.
        ctx_token = _api_key_ctx.set(token)
        log.debug("auth: ok %s %r", method, scope["path"])
        try:
            await self.app(scope, receive, send)
        finally:
            _api_key_ctx.reset(ctx_token)


# FastMCP v2 exposes the Starlette ASGI app via `http_app()`. Custom Starlette
# middleware must be passed via the `middleware=` kwarg so it wraps the inner
# app before FastMCP's own RequestContextMiddleware — `app.add_middleware`
# after construction would apply in the wrong order relative to the lifespan.
app = mcp.http_app(
    path="/",
    middleware=[Middleware(AuthMiddleware)],
)


if __name__ == "__main__":
    # uvicorn respects the lifespan wired into the Starlette app returned by
    # http_app(), so FastMCP's session manager starts/stops cleanly.
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level=LOG_LEVEL.lower())
