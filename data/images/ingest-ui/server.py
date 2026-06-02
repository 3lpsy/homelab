"""Ingest UI: combined upload + yt-dlp service plus internal pull API.

Two distinct surfaces:

  /api/*      — Tailnet-facing. Multi-user basic auth handled at the nginx
                layer; nginx forwards the authenticated user via the
                ``X-Remote-User`` header. The FastAPI app trusts that.

  /internal/* — Cluster-internal pull API for navidrome-ingest. nginx does
                NOT apply basic auth on this prefix; the FastAPI app
                requires ``Authorization: Bearer $INGEST_INTERNAL_TOKEN``
                and NetworkPolicy gates which pods can reach the Service
                in the first place.

Logging policy:
  - Filenames are not PII; we log them.
  - Bearer tokens, basic-auth credentials, and ``Authorization`` headers
    are never logged.
  - User identifiers (``X-Remote-User``) are logged.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import random
import re
import secrets
import shutil
import threading
import time
import urllib.parse
import uuid
import zipfile
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Literal

import yt_dlp
import yt_dlp.utils
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, HttpUrl
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger("ingest-ui")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


class _DropNoiseFilter(logging.Filter):
    """Suppress uvicorn access lines for high-frequency, low-signal paths.

    Filtered:
      - /healthz       — kubelet liveness/readiness, every ~5s
      - /favicon.ico   — browser auto-fires
      - /api/jobs      — the UI polls this on every refresh tick
      - /internal/...  — navidrome-ingest's poll loop, every 30s
                        (the per-call work is logged at app level
                        anyway: "internal serve / ack / quarantine")
    """

    _SUPPRESSED = ("/healthz", "/favicon.ico", "/api/jobs", "/internal/")

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return not any(p in msg for p in self._SUPPRESSED)


# Attach the filter to uvicorn's access logger; it's created at import
# time of uvicorn.logging, present by the time we get here.
logging.getLogger("uvicorn.access").addFilter(_DropNoiseFilter())

# ─────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────

DROPZONE_PATH = Path(os.environ.get("DROPZONE_PATH", "/dropzone"))
EXITNODE_PROXIES = [p for p in os.environ.get("EXITNODE_PROXIES", "").split() if p]
INDEX_HTML = Path(__file__).with_name("index.html")
JOB_HISTORY_LIMIT = int(os.environ.get("JOB_HISTORY_LIMIT", "200"))
YTDLP_TIMEOUT = int(os.environ.get("YTDLP_TIMEOUT", "1800"))
INTERNAL_TOKEN = os.environ.get("INGEST_INTERNAL_TOKEN", "")
ALLOWED_TARGETS: set[str] = {"music"}
AUDIO_EXTENSIONS = {".opus", ".mp3", ".flac", ".m4a", ".ogg", ".wav", ".aac", ".webm"}
SKIP_PATTERNS = (".part", ".tmp", ".!sync", ".crdownload", ".syncthing-temp")

# yt-dlp library config — see DownloadOptions below for the public surface.
YTDLP_AUDIO_CODEC = os.environ.get("YTDLP_AUDIO_CODEC", "opus")
YTDLP_RETRIES = int(os.environ.get("YTDLP_RETRIES", "3"))
YTDLP_FRAGMENT_RETRIES = int(os.environ.get("YTDLP_FRAGMENT_RETRIES", "3"))
YTDLP_CONCURRENT_FRAGMENTS = int(os.environ.get("YTDLP_CONCURRENT_FRAGMENTS", "4"))
# YouTube has gotten aggressive about bot detection. Two workarounds:
#   1. Try the mobile-web ('mweb') and TV ('tv') player clients before
#      'web' — they're less aggressively gated.
#   2. If a cookies file is available (mounted from Vault via CSI),
#      pass it to yt-dlp. Browser-exported cookies make yt-dlp look
#      like a logged-in session and bypass the "confirm you're not a
#      bot" gate.
YTDLP_PLAYER_CLIENTS = [
    c.strip()
    for c in os.environ.get("YTDLP_PLAYER_CLIENTS", "mweb,tv,web").split(",")
    if c.strip()
]
YTDLP_COOKIES_PATH = os.environ.get("YTDLP_COOKIES_PATH", "/mnt/secrets/ytdlp_cookies")
# Number of exit-node retries on bot-check / 403 / refused failures.
# Each retry picks a different unused exit. Capped at the actual pool
# size so we don't loop forever on a single available exit.
YTDLP_MAX_EXIT_RETRIES = int(os.environ.get("YTDLP_MAX_EXIT_RETRIES", "5"))
# Substrings that indicate an IP / reputation / bot-check failure
# (vs. a real video error like format unavailable). Lowercase compare.
_RETRYABLE_IP_ERROR_MARKERS = (
    "sign in to confirm",
    "you're not a bot",
    "403: forbidden",
    "http error 403",
    "blocked by",
    "rate limit",
    "too many requests",
    "429",
)
# Format selectors are restricted to the chars yt-dlp's grammar uses
# (alnum + a few separators / brackets / operators). Reject anything
# that could smuggle a path or shell metachar even though we no longer
# shell out — defence in depth.
FORMAT_PATTERN = re.compile(r"^[A-Za-z0-9+/\-,*\[\]<>=:.\s_]+$")


# ─────────────────────────────────────────────────────────────────────────
# Job book-keeping (uploads + yt-dlp downloads only — /internal/ is stateless)
# ─────────────────────────────────────────────────────────────────────────

@dataclass
class Job:
    id: str
    kind: Literal["upload", "download"]
    target: str
    status: Literal["queued", "running", "done", "failed"] = "queued"
    detail: str = ""
    files: list[str] = field(default_factory=list)
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    proxy: str | None = None

    def touch(self) -> None:
        self.updated_at = time.time()

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "target": self.target,
            "status": self.status,
            "detail": self.detail,
            "files": self.files,
            "error": self.error,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "proxy": self.proxy,
        }


JOBS: dict[str, Job] = {}
JOB_QUEUE: "asyncio.Queue[Job]" = asyncio.Queue()


# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────

def sanitize_filename(name: str) -> str:
    name = name.replace("/", "_").replace("\\", "_")
    name = re.sub(r"[\x00-\x1f\x7f]", "", name)
    name = re.sub(r"\s+", " ", name).strip().lstrip(".")
    return name or "unnamed"


def target_dir(target: str) -> Path:
    if target not in ALLOWED_TARGETS:
        raise HTTPException(400, f"target must be one of: {sorted(ALLOWED_TARGETS)}")
    p = DROPZONE_PATH / target
    p.mkdir(parents=True, exist_ok=True)
    return p


def remember_job(job: Job) -> None:
    JOBS[job.id] = job
    if len(JOBS) > JOB_HISTORY_LIMIT:
        oldest = sorted(JOBS.values(), key=lambda j: j.created_at)[: len(JOBS) - JOB_HISTORY_LIMIT]
        for j in oldest:
            JOBS.pop(j.id, None)


# ─────────────────────────────────────────────────────────────────────────
# /api/download request schema. Pydantic v2 enforces the contract; extra
# fields are rejected so unknown options can't sneak through.
# ─────────────────────────────────────────────────────────────────────────

class DownloadOptions(BaseModel):
    model_config = ConfigDict(extra="forbid")

    url: HttpUrl
    target: Literal["music"] = "music"
    audio_only: bool = True
    no_playlist: bool = True

    # Route through one of the exit-node tinyproxies (default) or hit
    # the upstream directly from the cluster's egress IP. Direct can
    # help on YouTube where ProtonVPN datacenter IPs trigger bot
    # detection — your home/cluster IP is residential to YouTube.
    # Tradeoff: requests visible to upstream as your home IP.
    use_exit_node: bool = True

    # Format selector validated against a yt-dlp-grammar charset only.
    format: str | None = Field(default=None, max_length=200)

    # Bounded knobs — yt-dlp accepts these, we cap them to limit blast radius.
    playlist_start: int | None = Field(default=None, ge=1, le=1000)
    playlist_end: int | None = Field(default=None, ge=1, le=1000)
    max_filesize_mb: int | None = Field(default=None, ge=1, le=2000)
    max_downloads: int | None = Field(default=None, ge=1, le=50)

    def validated_format(self) -> str | None:
        if self.format is None:
            return None
        f = self.format.strip()
        if not f:
            return None
        if not FORMAT_PATTERN.fullmatch(f):
            raise HTTPException(400, f"format string contains disallowed characters: {f!r}")
        return f


# ─────────────────────────────────────────────────────────────────────────
# yt-dlp library plumbing
# ─────────────────────────────────────────────────────────────────────────

class _CancelledByDeadline(Exception):
    """Raised inside a yt-dlp hook to abort a download past its deadline."""


class _JobLogger:
    """Adapter routing yt-dlp log messages into a job's detail buffer.

    yt-dlp's internal logger is duck-typed (debug/info/warning/error
    callables). We keep a bounded ring buffer per job so the API can
    surface the tail without growing unboundedly on long downloads.
    """

    def __init__(self, job: "Job", maxlines: int = 200) -> None:
        self.job = job
        self.maxlines = maxlines
        self._buf: list[str] = []

    def debug(self, msg: str) -> None:
        # yt-dlp passes "[debug] ..." through debug() at info level too;
        # filter the noisy ones to keep job.detail readable.
        if msg.startswith("[debug] "):
            return
        self._append(msg)

    def info(self, msg: str) -> None:
        self._append(msg)

    def warning(self, msg: str) -> None:
        self._append(f"WARN: {msg}")

    def error(self, msg: str) -> None:
        self._append(f"ERROR: {msg}")

    def _append(self, msg: str) -> None:
        self._buf.append(msg)
        if len(self._buf) > self.maxlines:
            del self._buf[: len(self._buf) - self.maxlines]
        # job.detail surfaces the tail through /api/jobs.
        self.job.detail = "\n".join(self._buf)
        self.job.touch()


def _progress_hook(job: "Job", cancel: threading.Event):
    def hook(d: dict[str, Any]) -> None:
        if cancel.is_set():
            raise _CancelledByDeadline(
                f"yt-dlp deadline exceeded ({YTDLP_TIMEOUT}s)"
            )
        status = d.get("status")
        if status == "downloading":
            pct = (d.get("_percent_str") or "").strip()
            speed = (d.get("_speed_str") or "").strip()
            eta = (d.get("_eta_str") or "").strip()
            parts = [p for p in (pct, speed, eta) if p]
            if parts:
                job.detail = f"downloading {' '.join(parts)}"
                job.touch()
        elif status == "finished":
            fname = d.get("filename")
            if fname:
                # Progress hook fires before postprocessing; we don't
                # know the final extension yet. Just record the name we
                # got and let _snapshot_files() rescan after run.
                job.detail = f"downloaded {Path(fname).name}, postprocessing..."
                job.touch()
    return hook


def build_ydl_opts(
    job: "Job",
    opts: DownloadOptions,
    out_template: str,
    proxy: str | None,
    cancel: threading.Event,
) -> dict[str, Any]:
    """Translate validated DownloadOptions into a yt-dlp library options dict.

    Pure function; tests instantiate with stub jobs to verify the mapping.
    """
    ydl_opts: dict[str, Any] = {
        "outtmpl": out_template,
        "noplaylist": opts.no_playlist,
        "quiet": True,
        "no_warnings": False,
        "no_color": True,
        "noprogress": True,  # we do our own via progress_hooks
        "logger": _JobLogger(job),
        "progress_hooks": [_progress_hook(job, cancel)],
        "concurrent_fragment_downloads": YTDLP_CONCURRENT_FRAGMENTS,
        "retries": YTDLP_RETRIES,
        "fragment_retries": YTDLP_FRAGMENT_RETRIES,
        # Don't continue past per-video errors when the user submits a
        # single URL — surface the failure immediately.
        "ignoreerrors": False,
        # Restrict filenames to ASCII-safe bytes so downstream tools
        # (mutagen, navidrome scan) don't choke on weird UTF-8.
        "restrictfilenames": False,
    }
    if proxy:
        ydl_opts["proxy"] = proxy

    # YouTube bot-check workarounds (no-op for non-youtube extractors).
    if YTDLP_PLAYER_CLIENTS:
        ydl_opts["extractor_args"] = {"youtube": {"player_client": YTDLP_PLAYER_CLIENTS}}
    cookies_path = Path(YTDLP_COOKIES_PATH)
    if cookies_path.is_file() and cookies_path.stat().st_size > 0:
        ydl_opts["cookiefile"] = str(cookies_path)

    fmt = opts.validated_format()
    if fmt:
        ydl_opts["format"] = fmt
    elif opts.audio_only:
        ydl_opts["format"] = "bestaudio/best"

    if opts.audio_only:
        ydl_opts["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": YTDLP_AUDIO_CODEC,
            }
        ]

    if opts.playlist_start is not None:
        ydl_opts["playliststart"] = opts.playlist_start
    if opts.playlist_end is not None:
        ydl_opts["playlistend"] = opts.playlist_end
    if opts.max_filesize_mb is not None:
        ydl_opts["max_filesize"] = opts.max_filesize_mb * 1024 * 1024
    if opts.max_downloads is not None:
        ydl_opts["max_downloads"] = opts.max_downloads

    return ydl_opts


def _do_download_blocking(ydl_opts: dict[str, Any], url: str) -> None:
    """Sync entry point that runs in a worker thread under asyncio.to_thread()."""
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ydl.extract_info(url, download=True)


def _snapshot_audio_outputs(dest_dir: Path, since_mtime: float) -> list[str]:
    """Find audio files that landed in `dest_dir` after `since_mtime`."""
    out: list[str] = []
    for p in sorted(dest_dir.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if not p.is_file():
            continue
        if p.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        if p.stat().st_mtime < since_mtime:
            break
        out.append(p.name)
        if len(out) >= 25:
            break
    return out


# ─────────────────────────────────────────────────────────────────────────
# Internal API helpers — file id is base64url(sha1(rel_path)) so it's
# stable across polls and survives URL-encoding.
# ─────────────────────────────────────────────────────────────────────────

def file_id_for(path: Path) -> str:
    rel = path.relative_to(DROPZONE_PATH).as_posix()
    digest = hashlib.sha1(rel.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def list_dropzone_music() -> list[dict[str, Any]]:
    music_dir = DROPZONE_PATH / "music"
    if not music_dir.exists():
        return []
    out: list[dict[str, Any]] = []
    for p in sorted(music_dir.iterdir()):
        if p.is_dir():
            continue
        if p.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        if any(part in p.name for part in SKIP_PATTERNS):
            continue
        try:
            stat = p.stat()
        except FileNotFoundError:
            continue
        out.append({
            "id": file_id_for(p),
            "filename": p.name,
            "size": stat.st_size,
            "mtime": stat.st_mtime,
        })
    return out


def find_dropzone_file(file_id: str) -> Path:
    """Return the path to the file with the given id, or raise 404."""
    music_dir = DROPZONE_PATH / "music"
    if not music_dir.exists():
        raise HTTPException(404, "no such file")
    for p in music_dir.iterdir():
        if p.is_dir():
            continue
        if file_id_for(p) == file_id:
            return p
    raise HTTPException(404, "no such file")


# ─────────────────────────────────────────────────────────────────────────
# Bearer-auth middleware (only for /internal/*)
# ─────────────────────────────────────────────────────────────────────────

class InternalBearerAuth(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path.startswith("/internal/"):
            if not INTERNAL_TOKEN:
                logger.error("INGEST_INTERNAL_TOKEN unset; rejecting /internal/* request")
                return JSONResponse({"detail": "internal auth disabled"}, status_code=503)
            header = request.headers.get("authorization", "")
            scheme, _, value = header.partition(" ")
            if scheme.lower() != "bearer" or not secrets.compare_digest(value, INTERNAL_TOKEN):
                # Don't echo the bad token. Log only the source + path.
                client = request.client.host if request.client else "?"
                logger.warning("internal auth rejected client=%s path=%s", client, request.url.path)
                return JSONResponse({"detail": "unauthorized"}, status_code=401)
        return await call_next(request)


# ─────────────────────────────────────────────────────────────────────────
# Upload + download workers
# ─────────────────────────────────────────────────────────────────────────

async def write_upload_to_target(file: UploadFile, target: str) -> list[str]:
    dest_dir = target_dir(target)
    written: list[str] = []
    safe_name = sanitize_filename(file.filename or "upload.bin")

    tmp_dir = DROPZONE_PATH / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"{uuid.uuid4().hex}-{safe_name}"
    try:
        with tmp_path.open("wb") as fh:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                fh.write(chunk)

        if safe_name.lower().endswith(".zip"):
            with zipfile.ZipFile(tmp_path) as zf:
                for member in zf.infolist():
                    if member.is_dir():
                        continue
                    member_name = sanitize_filename(Path(member.filename).name)
                    if not member_name:
                        continue
                    out_path = dest_dir / f"{uuid.uuid4().hex[:8]}-{member_name}"
                    with zf.open(member) as src, out_path.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
                    out_path.chmod(0o644)
                    written.append(out_path.name)
            tmp_path.unlink(missing_ok=True)
        else:
            out_path = dest_dir / f"{uuid.uuid4().hex[:8]}-{safe_name}"
            tmp_path.rename(out_path)
            out_path.chmod(0o644)
            written.append(out_path.name)
    finally:
        tmp_path.unlink(missing_ok=True)

    return written


def _is_retryable_ip_error(err: BaseException) -> bool:
    """Return True if the error suggests rotating the exit-node IP."""
    s = str(err).lower()
    return any(m in s for m in _RETRYABLE_IP_ERROR_MARKERS)


def _build_proxy_rotation(use_exit_node: bool) -> list[str | None]:
    """Return an ordered list of proxies to try, capped by retry budget.

    `use_exit_node=False` -> single direct attempt, no rotation.
    No exit pool configured -> single direct attempt.
    Otherwise -> shuffled, capped at YTDLP_MAX_EXIT_RETRIES.
    """
    if not use_exit_node or not EXITNODE_PROXIES:
        return [None]
    pool = list(EXITNODE_PROXIES)
    random.shuffle(pool)
    return pool[: max(1, YTDLP_MAX_EXIT_RETRIES)]


async def _attempt_download(
    job: Job, opts: DownloadOptions, dest_dir: Path, out_template: str, proxy: str | None
) -> None:
    """Single yt-dlp attempt. Raises on failure (caller decides retry)."""
    cancel = threading.Event()
    ydl_opts = build_ydl_opts(job, opts, out_template, proxy, cancel)
    try:
        await asyncio.wait_for(
            asyncio.to_thread(_do_download_blocking, ydl_opts, str(opts.url)),
            timeout=YTDLP_TIMEOUT,
        )
    except asyncio.TimeoutError:
        cancel.set()
        raise RuntimeError(f"yt-dlp timed out after {YTDLP_TIMEOUT}s")
    except yt_dlp.utils.MaxDownloadsReached:
        logger.info("yt-dlp job=%s reached max_downloads cap", job.id)
    except _CancelledByDeadline as e:
        raise RuntimeError(str(e))


async def run_download(job: Job, opts: DownloadOptions) -> None:
    """Drive a yt-dlp download for a single job, retrying across exit
    nodes on IP-reputation failures (bot-check, 403, rate limit).

    yt-dlp itself runs blocking in a worker thread (asyncio.to_thread)
    so the FastAPI event loop stays responsive. Cancellation on timeout
    is delivered through a `cancel` threading.Event, checked from every
    progress_hook callback. If yt-dlp is wedged outside a hook (rare:
    DNS or extractor init), the FastAPI handler still returns on
    timeout — the orphan thread finishes naturally without blocking
    new jobs.

    Retry strategy:
      - For IP/bot/403/rate-limit errors -> rotate to next exit-node.
      - For all other errors (extractor refused, format mismatch,
        actual unreachable host) -> surface immediately, no retry.
      - Hard cap on attempts: min(YTDLP_MAX_EXIT_RETRIES, len(EXITNODE_PROXIES)).
    """
    dest_dir = target_dir(opts.target)
    out_template = str(dest_dir / "%(title)s [%(id)s].%(ext)s")
    proxies = _build_proxy_rotation(opts.use_exit_node)

    started_mtime = time.time()
    last_err: BaseException | None = None

    for attempt, proxy in enumerate(proxies, start=1):
        job.proxy = proxy or "direct"
        logger.info(
            "yt-dlp attempt=%d/%d job=%s url=%s proxy=%s audio_only=%s no_playlist=%s",
            attempt, len(proxies), job.id, opts.url, job.proxy,
            opts.audio_only, opts.no_playlist,
        )
        try:
            await _attempt_download(job, opts, dest_dir, out_template, proxy)
            last_err = None
            break  # success
        except yt_dlp.utils.DownloadError as e:
            if _is_retryable_ip_error(e) and attempt < len(proxies):
                logger.warning(
                    "yt-dlp ip-flagged attempt=%d/%d job=%s proxy=%s; rotating",
                    attempt, len(proxies), job.id, job.proxy,
                )
                last_err = e
                continue
            raise RuntimeError(f"yt-dlp download failed: {e}")
        except RuntimeError as e:
            # Timeout or cancellation — surface immediately.
            raise

    if last_err is not None:
        # Loop exited via continue path (all retries exhausted).
        raise RuntimeError(
            f"yt-dlp failed after {len(proxies)} exit-node attempts; last: {last_err}"
        )

    job.files = _snapshot_audio_outputs(dest_dir, started_mtime)
    if not job.files:
        raise RuntimeError("yt-dlp produced no audio output (format mismatch?)")


async def worker_loop(stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            job = await asyncio.wait_for(JOB_QUEUE.get(), timeout=1.0)
        except asyncio.TimeoutError:
            continue
        try:
            job.status = "running"
            job.touch()
            if job.kind == "upload":
                # uploads are handled inline in /api/upload; this path
                # only sees them if a future caller queues one.
                job.status = "done"
            elif job.kind == "download":
                opts: DownloadOptions = getattr(job, "_validated_opts")
                await run_download(job, opts)
                job.status = "done"
        except RuntimeError as exc:
            # Known/expected runtime failures (yt-dlp HTTP error,
            # extractor refusal, etc.) — short log without traceback.
            # Domain message + job id is enough for triage.
            job.status = "failed"
            job.error = str(exc)
            logger.error("job %s failed: %s", job.id, exc)
        except Exception as exc:  # noqa: BLE001
            # Anything else is unexpected — keep the traceback.
            job.status = "failed"
            job.error = str(exc)
            logger.exception("job %s failed (unexpected)", job.id)
        finally:
            job.touch()
            JOB_QUEUE.task_done()


# ─────────────────────────────────────────────────────────────────────────
# App
# ─────────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    DROPZONE_PATH.mkdir(parents=True, exist_ok=True)
    for sub in ("music", "music/failed", "tmp"):
        (DROPZONE_PATH / sub).mkdir(parents=True, exist_ok=True)
    if not INTERNAL_TOKEN:
        logger.warning("INGEST_INTERNAL_TOKEN is empty — /internal/* will return 503")
    stop = asyncio.Event()
    task = asyncio.create_task(worker_loop(stop))
    try:
        yield
    finally:
        # Graceful: signal the worker, drain in-flight, then cancel if needed.
        stop.set()
        try:
            await asyncio.wait_for(JOB_QUEUE.join(), timeout=10)
        except asyncio.TimeoutError:
            logger.warning("worker queue did not drain within 10s; cancelling")
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="ingest-ui", lifespan=lifespan)
app.add_middleware(InternalBearerAuth)


# ── Public + tailnet-auth UI ────────────────────────────────────────────

@app.get("/")
async def index() -> FileResponse:
    return FileResponse(INDEX_HTML)


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    return {
        "ok": True,
        "exit_proxies": len(EXITNODE_PROXIES),
        "queue_depth": JOB_QUEUE.qsize(),
        "internal_auth_configured": bool(INTERNAL_TOKEN),
    }


@app.get("/api/jobs")
async def jobs() -> dict[str, Any]:
    return {"jobs": [j.to_json() for j in sorted(JOBS.values(), key=lambda j: j.created_at, reverse=True)]}


@app.post("/api/upload")
async def upload(
    request: Request,
    target: str = Form("music"),
    file: UploadFile = File(...),
) -> dict[str, Any]:
    user = request.headers.get("x-remote-user", "?")
    written = await write_upload_to_target(file, target)
    job = Job(
        id=uuid.uuid4().hex[:12],
        kind="upload",
        target=target,
        status="done",
        files=written,
        detail=f"user={user} files={len(written)}",
    )
    remember_job(job)
    logger.info("upload user=%s target=%s files=%d", user, target, len(written))
    return {"job": job.to_json()}


@app.post("/api/download")
async def download(opts: DownloadOptions, request: Request) -> JSONResponse:
    """Submit a yt-dlp download job.

    The body is validated by Pydantic against `DownloadOptions`:
    unknown fields are rejected (extra="forbid"), the URL is parsed as
    HttpUrl, ints are bounded, and the format selector — if any — is
    further sanity-checked against a yt-dlp grammar charset before yt-dlp
    sees it.
    """
    user = request.headers.get("x-remote-user", "?")
    job = Job(
        id=uuid.uuid4().hex[:12],
        kind="download",
        target=opts.target,
        detail=f"user={user} url={opts.url}",
    )
    # _validated_opts is the full opts payload, kept on the job for the
    # worker_loop to dispatch.
    job._validated_opts = opts  # type: ignore[attr-defined]
    remember_job(job)
    await JOB_QUEUE.put(job)
    logger.info(
        "download user=%s url=%s target=%s audio_only=%s",
        user, opts.url, opts.target, opts.audio_only,
    )
    return JSONResponse({"job": job.to_json()})


# ── /internal/* — bearer-token-auth pull API for navidrome-ingest ──────

@app.get("/internal/dropzone/list")
async def internal_list() -> dict[str, Any]:
    items = list_dropzone_music()
    # Empty polls happen every 30s and add nothing to the log; only
    # surface when there's actual work.
    if items:
        logger.info("internal list returned=%d", len(items))
    return {"files": items}


@app.get("/internal/dropzone/file/{file_id}")
async def internal_file(file_id: str) -> StreamingResponse:
    path = find_dropzone_file(file_id)

    async def streamer() -> AsyncIterator[bytes]:
        with path.open("rb") as fh:
            while True:
                chunk = fh.read(64 * 1024)
                if not chunk:
                    break
                yield chunk

    # HTTP headers are latin-1; non-ASCII filenames (e.g. YouTube titles
    # with full-width unicode like `＂`) need RFC 5987 encoding. We expose
    # the URL-encoded form on `X-Filename` (clients decode), and the
    # standard `filename*=UTF-8''...` field on Content-Disposition.
    encoded = urllib.parse.quote(path.name, safe="")
    headers = {
        "X-Filename": encoded,
        "Content-Disposition": f"attachment; filename*=UTF-8''{encoded}",
    }
    logger.info("internal serve file=%s size=%d", path.name, path.stat().st_size)
    return StreamingResponse(streamer(), media_type="application/octet-stream", headers=headers)


@app.post("/internal/dropzone/ack/{file_id}")
async def internal_ack(file_id: str) -> JSONResponse:
    path = find_dropzone_file(file_id)
    name = path.name
    path.unlink(missing_ok=True)
    logger.info("internal ack file=%s", name)
    return JSONResponse({"acked": name}, status_code=200)


@app.post("/internal/dropzone/quarantine/{file_id}")
async def internal_quarantine(file_id: str, request: Request) -> JSONResponse:
    path = find_dropzone_file(file_id)
    body: dict[str, Any] = {}
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        pass
    reason = str(body.get("reason", "unspecified"))
    failed_dir = DROPZONE_PATH / "music" / "failed"
    failed_dir.mkdir(parents=True, exist_ok=True)
    dest = failed_dir / path.name
    if dest.exists():
        dest = dest.with_name(f"{dest.stem}-{uuid.uuid4().hex[:6]}{dest.suffix}")
    path.rename(dest)
    sidecar = dest.with_suffix(dest.suffix + ".error.json")
    sidecar.write_text(json.dumps({"reason": reason, "ts": time.time()}, indent=2))
    logger.info("internal quarantine file=%s reason=%s", dest.name, reason)
    return JSONResponse({"quarantined": dest.name, "reason": reason}, status_code=200)
