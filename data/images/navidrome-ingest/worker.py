"""Pull dropzone files from ingest-ui, tag via LiteLLM, write to navidrome-music.

Poll loop:
  1. GET /internal/dropzone/list                      — what's pending
  2. For each file:
       GET  /internal/dropzone/file/<id>              — download bytes
       compute audio-stream md5 → if already in library, ack as dupe
       probe + LLM tag
       if confidence >= threshold:
           write tags + os.rename into /music/<artist>/<title>.<ext>
           POST /internal/dropzone/ack/<id>
       else:
           POST /internal/dropzone/quarantine/<id> {"reason": ...}

Dedup index:
  An in-memory map of audio-stream md5 → relative library path. The
  ingestor rewrites tags via mutagen, which mutates file bytes — so the
  raw file md5 is unstable across re-tag. ffmpeg's `-f md5` over the
  decoded audio stream (`-map 0:a`) ignores tag chunks and stays stable.
  Index rebuilds on startup and every INDEX_REBUILD_INTERVAL seconds.

Logging policy:
  - Filenames are not PII; we log them.
  - Bearer tokens, response bodies on auth errors, and any header values
    other than ``X-Filename`` are never logged.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import signal
import tempfile
import time
import unicodedata
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import av
import httpx
import jinja2
import litellm
import mutagen
from aiohttp import web
from mutagen.easyid3 import EasyID3
from mutagen.flac import FLAC
from mutagen.id3 import TALB, TCON, TDRC, TIT2, TPE1
from mutagen.mp4 import MP4
from mutagen.oggopus import OggOpus
from mutagen.oggvorbis import OggVorbis
from mutagen.wave import WAVE

logger = logging.getLogger("navidrome-ingest")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

# Silence noisy third-party loggers. aiohttp.access produces one line per
# kube-probe hit on /healthz (every 10s); litellm + LiteLLM print per-call
# "Wrapper: Completed Call" on every tag invocation; httpx prints every
# poll. Promote them to WARNING so only real problems show up.
for _noisy in ("aiohttp.access", "litellm", "LiteLLM", "httpx"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)

# ─────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────

MUSIC_PATH = Path(os.environ.get("MUSIC_PATH", "/music"))
PROMPT_PATH = Path(os.environ.get("PROMPT_PATH", "/etc/ingest/prompt.j2"))
SCHEMA_PATH = Path(os.environ.get("SCHEMA_PATH", "/etc/ingest/schema.json"))
LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "https://litellm.example/")
LITELLM_MODEL = os.environ.get("LITELLM_MODEL", "default-qwen-3.5-4b")
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "")
CONFIDENCE_THRESHOLD = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.5"))
HEALTH_PORT = int(os.environ.get("HEALTH_PORT", "8090"))

INGEST_BASE_URL = os.environ.get("INGEST_BASE_URL", "https://ingest.example/")
INGEST_INTERNAL_TOKEN = os.environ.get("INGEST_INTERNAL_TOKEN", "")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "30"))
POLL_TIMEOUT = float(os.environ.get("POLL_TIMEOUT", "20"))
DOWNLOAD_TIMEOUT = float(os.environ.get("DOWNLOAD_TIMEOUT", "300"))
INDEX_REBUILD_INTERVAL = float(os.environ.get("INDEX_REBUILD_INTERVAL", "3600"))
HASH_TIMEOUT = float(os.environ.get("HASH_TIMEOUT", "60"))

AUDIO_EXTENSIONS = {".opus", ".mp3", ".flac", ".m4a", ".ogg", ".wav", ".aac"}


# ─────────────────────────────────────────────────────────────────────────
# Tag helpers
# ─────────────────────────────────────────────────────────────────────────

def read_existing_tags(path: Path) -> dict[str, str]:
    try:
        m = mutagen.File(path, easy=True)
    except Exception:  # noqa: BLE001
        return {}
    if m is None:
        return {}
    out: dict[str, str] = {}
    for k, v in (m.tags or {}).items():
        if isinstance(v, list) and v:
            out[str(k)] = str(v[0])
        else:
            out[str(k)] = str(v)
    return out


def probe_audio(path: Path) -> dict[str, Any]:
    try:
        f = mutagen.File(path)
    except Exception as e:  # noqa: BLE001
        return {"duration_s": None, "codec": None, "error": str(e)}
    if f is None or f.info is None:
        return {"duration_s": None, "codec": None}
    return {
        "duration_s": int(getattr(f.info, "length", 0) or 0),
        "codec": type(f).__name__,
    }


def write_tags(path: Path, *, artist: str, title: str, album: str | None, genre: str | None, year: str | None) -> None:
    suffix = path.suffix.lower()
    tags: dict[str, list[str]] = {"artist": [artist], "title": [title]}
    if album:
        tags["album"] = [album]
    if genre:
        tags["genre"] = [genre]
    if year:
        tags["date"] = [year]

    if suffix == ".mp3":
        try:
            audio = EasyID3(path)
        except Exception:
            audio = mutagen.File(path, easy=True)
            if audio is None or audio.tags is None:
                audio = EasyID3()
                audio.save(path)
                audio = EasyID3(path)
        for k, v in tags.items():
            audio[k] = v
        audio.save(path)
    elif suffix in {".opus", ".ogg"}:
        audio_cls = OggOpus if suffix == ".opus" else OggVorbis
        audio = audio_cls(path)
        for k, v in tags.items():
            audio[k] = v
        audio.save()
    elif suffix == ".flac":
        audio = FLAC(path)
        for k, v in tags.items():
            audio[k] = v
        audio.save()
    elif suffix in {".m4a", ".aac"}:
        audio = MP4(path)
        atom_map = {
            "artist": "\xa9ART",
            "title": "\xa9nam",
            "album": "\xa9alb",
            "genre": "\xa9gen",
            "date": "\xa9day",
        }
        for k, v in tags.items():
            audio[atom_map[k]] = v
        audio.save()
    elif suffix == ".wav":
        # WAV uses ID3v2 frames embedded in the RIFF container. Most
        # players (Navidrome, foobar, mpv) read these. Mutagen's WAVE
        # class wraps an ID3 instance.
        audio = WAVE(path)
        if audio.tags is None:
            audio.add_tags()
        audio.tags.add(TPE1(encoding=3, text=artist))
        audio.tags.add(TIT2(encoding=3, text=title))
        if album:
            audio.tags.add(TALB(encoding=3, text=album))
        if genre:
            audio.tags.add(TCON(encoding=3, text=genre))
        if year:
            audio.tags.add(TDRC(encoding=3, text=year))
        audio.save()
    else:
        logger.warning("write_tags: unsupported format suffix=%s", suffix)


# ─────────────────────────────────────────────────────────────────────────
# LLM call
# ─────────────────────────────────────────────────────────────────────────

def load_prompt_template() -> jinja2.Template:
    src = PROMPT_PATH.read_text() if PROMPT_PATH.exists() else (
        "Filename: {{ filename }}\n"
        "Folder: {{ parent_dir }}\n"
        "Existing tags: {{ existing_tags }}\n"
        "Duration (s): {{ duration_s }}\n"
        "Codec: {{ codec }}\n"
        "Extract structured tag info using the tag_track tool."
    )
    return jinja2.Template(src)


def load_schema() -> dict[str, Any]:
    if SCHEMA_PATH.exists():
        return json.loads(SCHEMA_PATH.read_text())
    return {
        "type": "object",
        "required": ["artist", "title", "confidence"],
        "properties": {
            "artist": {"type": "string"},
            "title": {"type": "string"},
            "album": {"type": "string"},
            "genre": {"type": "string"},
            "year": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        },
    }


@dataclass
class TagResult:
    artist: str
    title: str
    album: str | None
    genre: str | None
    year: str | None
    confidence: float

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "TagResult":
        return cls(
            artist=str(payload.get("artist", "")).strip(),
            title=str(payload.get("title", "")).strip(),
            album=(str(payload["album"]).strip() or None) if payload.get("album") else None,
            genre=(str(payload["genre"]).strip() or None) if payload.get("genre") else None,
            year=(str(payload["year"]).strip() or None) if payload.get("year") else None,
            confidence=float(payload.get("confidence", 0)),
        )


def _tolerant_json_loads(s: str) -> dict[str, Any] | None:
    """Best-effort parse of LLM-emitted JSON. Returns None on total failure.

    Handles common LLM quirks:
      - Markdown code fences (```json ... ```)
      - Leading prose before the JSON object
      - Trailing prose after
      - Mid-string truncation (closes the open string + braces)
    """
    if not s:
        return None
    text = s.strip()

    # Strip markdown fences if present.
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, count=1)
        text = re.sub(r"\s*```\s*$", "", text, count=1)
        text = text.strip()

    # Direct parse first.
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Slice between first '{' and last '}'.
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        candidate = text[start:end + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass

    # Truncation repair: count unbalanced braces and quotes, close them.
    if start >= 0:
        candidate = text[start:]
        # Drop any trailing partial token after the last comma if mid-string.
        # Heuristic: if odd number of unescaped quotes, close the string.
        unescaped_quotes = len(re.findall(r'(?<!\\)"', candidate))
        if unescaped_quotes % 2 == 1:
            candidate += '"'
        # Balance braces.
        opens = candidate.count("{")
        closes = candidate.count("}")
        if opens > closes:
            candidate += "}" * (opens - closes)
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass

    return None


def _try_completion(
    *,
    routed_model: str,
    messages: list[dict[str, Any]],
    schema: dict[str, Any],
    use_tool_call: bool,
) -> TagResult | None:
    """Single LiteLLM call. Returns a TagResult if it parsed cleanly, else None.

    Two modes:
      - use_tool_call=True: tool_choice forces the model to emit tool_call.arguments.
      - use_tool_call=False: response_format JSON mode, parse from message.content.
    """
    common_kwargs: dict[str, Any] = dict(
        model=routed_model,
        api_base=LITELLM_BASE_URL,
        api_key=LITELLM_API_KEY,
        messages=messages,
        max_tokens=2000,  # tag JSON should fit in <300 tokens; 2000 leaves slack
        temperature=0.0,
    )

    if use_tool_call:
        tool_def = {
            "type": "function",
            "function": {
                "name": "tag_track",
                "description": "Emit structured tag info parsed from the filename and metadata.",
                "parameters": schema,
            },
        }
        common_kwargs["tools"] = [tool_def]
        common_kwargs["tool_choice"] = {"type": "function", "function": {"name": "tag_track"}}
    else:
        common_kwargs["response_format"] = {"type": "json_object"}

    try:
        response = litellm.completion(**common_kwargs)
    except Exception as exc:  # noqa: BLE001
        logger.warning("LLM call failed mode=%s err=%s", "tool" if use_tool_call else "json", exc)
        return None

    msg = response["choices"][0]["message"]
    tool_calls = msg.get("tool_calls") if isinstance(msg, dict) else getattr(msg, "tool_calls", None)

    payload: dict[str, Any] | None = None
    if use_tool_call and tool_calls:
        raw_args = (
            tool_calls[0]["function"]["arguments"]
            if isinstance(tool_calls[0], dict)
            else tool_calls[0].function.arguments
        )
        if isinstance(raw_args, str):
            payload = _tolerant_json_loads(raw_args)
            if payload is None:
                logger.warning(
                    "tool_call args parse failed model=%s args=%r",
                    routed_model, raw_args[:400].replace("\n", " "),
                )
        else:
            payload = raw_args  # already dict
    else:
        # No tool call (or json mode): parse JSON out of content.
        content = msg.get("content") if isinstance(msg, dict) else getattr(msg, "content", "")
        if content:
            payload = _tolerant_json_loads(content)
            if payload is None:
                logger.warning(
                    "content parse failed mode=%s model=%s content=%r",
                    "tool-fallback" if use_tool_call else "json",
                    routed_model,
                    content[:400].replace("\n", " "),
                )
        else:
            logger.warning(
                "empty response mode=%s model=%s", "tool" if use_tool_call else "json", routed_model
            )

    if payload is None:
        return None
    return TagResult.from_payload(payload)


def call_llm(filename: str, parent_dir: str, tags: dict[str, str], duration_s: int | None, codec: str | None) -> TagResult:
    """Tag a single file via LiteLLM. Tries tool-call mode first, then
    falls back to JSON-mode (response_format) on empty/unparseable response.
    Both attempts are bounded to one network call each — at most two LLM
    invocations per file.
    """
    template = load_prompt_template()
    schema = load_schema()

    rendered = template.render(
        filename=filename,
        parent_dir=parent_dir,
        existing_tags=json.dumps(tags, ensure_ascii=False),
        duration_s=duration_s,
        codec=codec,
    )

    # `openai/` prefix tells the litellm SDK to use OpenAI-compatible HTTP
    # against api_base (our LiteLLM proxy) rather than dispatching to a
    # local provider mapping for the alias. The proxy resolves the alias
    # to the real upstream model.
    routed_model = LITELLM_MODEL if "/" in LITELLM_MODEL else f"openai/{LITELLM_MODEL}"

    system_msg = (
        "You parse music filenames into structured tags. YouTube-style edits, "
        "AMVs, and remix uploads are common — do not invent album names; leave "
        "them null when unknown. Confidence must reflect how clearly artist+title "
        "can be read from the filename. Respond with the exact JSON shape "
        "expected by the schema; do not add prose."
    )
    messages = [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": rendered},
    ]

    # Attempt 1: tool-call (most reliable when the model supports it).
    result = _try_completion(
        routed_model=routed_model, messages=messages, schema=schema, use_tool_call=True
    )
    if result is not None and (result.confidence > 0 or result.artist or result.title):
        return result

    # Attempt 2: JSON-mode fallback for models that misbehave with tools.
    logger.info("tool-call attempt yielded nothing; retrying in json-mode model=%s", routed_model)
    result = _try_completion(
        routed_model=routed_model, messages=messages, schema=schema, use_tool_call=False
    )
    if result is not None:
        return result

    return TagResult(artist="", title="", album=None, genre=None, year=None, confidence=0.0)


def parse_tags_from_text(content: str) -> TagResult:
    match = re.search(r"\{[\s\S]*\}", content)
    if not match:
        return TagResult(artist="", title="", album=None, genre=None, year=None, confidence=0.0)
    try:
        payload = json.loads(match.group(0))
    except json.JSONDecodeError:
        return TagResult(artist="", title="", album=None, genre=None, year=None, confidence=0.0)
    return TagResult.from_payload(payload)


# ─────────────────────────────────────────────────────────────────────────
# Path helpers
# ─────────────────────────────────────────────────────────────────────────

_FS_RESERVED = re.compile(r'[<>:"|?*]')


def sanitize_path_segment(seg: str) -> str:
    """Normalize a single path segment for the music library.

    - NFKC normalize: fullwidth unicode (＂ ｜ ＇) collapses to ASCII (`"` `|` `'`).
      Latin diacritics are preserved (café stays café). CJK stays CJK.
    - Drop control chars and filesystem-reserved chars common to Windows
      (defensive — local-path is Linux but we may rsync to other targets).
    - Collapse whitespace, trim trailing dots/spaces (Windows hates them).
    - Empty result falls back to "unknown".
    """
    if not seg:
        return "unknown"
    seg = unicodedata.normalize("NFKC", seg)
    seg = re.sub(r"[\x00-\x1f\x7f]", "", seg)
    seg = seg.replace("/", "_").replace("\\", "_")
    seg = _FS_RESERVED.sub("", seg)
    seg = re.sub(r"\s+", " ", seg).strip()
    seg = seg.rstrip(". ")
    return seg or "unknown"


def target_path(artist: str, title: str, suffix: str) -> Path:
    return MUSIC_PATH / sanitize_path_segment(artist) / f"{sanitize_path_segment(title)}{suffix}"


def unique_path(p: Path) -> Path:
    if not p.exists():
        return p
    return p.with_name(f"{p.stem}-{uuid.uuid4().hex[:6]}{p.suffix}")


def is_audio(name: str) -> bool:
    return Path(name).suffix.lower() in AUDIO_EXTENSIONS


# ─────────────────────────────────────────────────────────────────────────
# Audio-stream hash + library dedup index
# ─────────────────────────────────────────────────────────────────────────

# Hash the raw audio packet bytes via PyAV (libavformat). No decode —
# we just iterate demuxed packets and feed `bytes(packet)` into md5.
# Stable across mutagen re-tag because only the ID3/Vorbis container
# chunks change, not the encoded audio packets themselves. Runs in a
# worker thread because PyAV's demux loop is blocking.
def _audio_hash_blocking(path: Path) -> str | None:
    import hashlib
    try:
        container = av.open(str(path))
    except av.FFmpegError as e:
        logger.warning("compute_audio_hash open failed file=%s err=%s", path, e)
        return None
    try:
        audio_streams = [s for s in container.streams if s.type == "audio"]
        if not audio_streams:
            logger.warning("compute_audio_hash no audio stream file=%s", path)
            return None
        h = hashlib.md5()
        for packet in container.demux(audio_streams[0]):
            data = bytes(packet)
            if data:
                h.update(data)
        digest = h.hexdigest()
        if digest == hashlib.md5(b"").hexdigest():
            # No packets read at all — treat as failure rather than collide
            # every empty/broken file under one hash.
            logger.warning("compute_audio_hash empty packet stream file=%s", path)
            return None
        return digest
    except av.FFmpegError as e:
        logger.warning("compute_audio_hash demux failed file=%s err=%s", path, e)
        return None
    finally:
        container.close()


async def compute_audio_hash(path: Path) -> str | None:
    """Return md5 hex of the audio packet stream, or None on failure.

    Bounded by HASH_TIMEOUT seconds; the blocking PyAV work runs in a
    thread. Tag chunks (ID3v2, Vorbis comments, MP4 atoms) are skipped
    by design since we hash demuxed packets, not the file bytes.
    """
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(_audio_hash_blocking, path),
            timeout=HASH_TIMEOUT,
        )
    except asyncio.TimeoutError:
        logger.warning("compute_audio_hash timeout file=%s", path)
        return None


class LibraryIndex:
    """In-memory audio-stream-md5 -> relative library path index.

    Rebuilt on startup and on a timer. Per-ingest inserts mutate it under
    a lock so a rebuild can't race with an `add()` from `process_one`.
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        self._hashes: dict[str, str] = {}  # md5 -> relpath
        self._lock = asyncio.Lock()
        self.last_rebuild_at: float = 0.0
        self.last_rebuild_size: int = 0

    async def contains(self, audio_md5: str) -> str | None:
        async with self._lock:
            return self._hashes.get(audio_md5)

    async def add(self, path: Path, audio_md5: str) -> None:
        try:
            rel = str(path.relative_to(self.root))
        except ValueError:
            rel = str(path)
        async with self._lock:
            self._hashes[audio_md5] = rel

    async def rebuild(self) -> None:
        """Walk the music root, hash every audio file, replace the map."""
        start = time.time()
        new_map: dict[str, str] = {}
        files = [p for p in self.root.rglob("*") if p.is_file() and is_audio(p.name)]
        for p in files:
            h = await compute_audio_hash(p)
            if h is None:
                continue
            try:
                rel = str(p.relative_to(self.root))
            except ValueError:
                rel = str(p)
            # Last-writer-wins on collision: surface in logs.
            if h in new_map and new_map[h] != rel:
                logger.info("index: dupe in library hash=%s a=%s b=%s", h, new_map[h], rel)
            new_map[h] = rel
        async with self._lock:
            self._hashes = new_map
            self.last_rebuild_at = time.time()
            self.last_rebuild_size = len(new_map)
        logger.info(
            "index rebuilt size=%d files=%d elapsed=%.1fs",
            len(new_map), len(files), time.time() - start,
        )


INDEX = LibraryIndex(MUSIC_PATH)


async def index_refresh_loop(stop: asyncio.Event) -> None:
    """Rebuild the dedup index on a timer.

    Initial rebuild runs in `lifespan` before the poll loop starts so the
    first pull cycle already has an up-to-date library map. After that we
    refresh in the background; per-ingest `add()` keeps the map fresh
    between rebuilds.
    """
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=INDEX_REBUILD_INTERVAL)
            return  # stop fired
        except asyncio.TimeoutError:
            pass
        try:
            await INDEX.rebuild()
        except Exception:  # noqa: BLE001
            logger.exception("index rebuild failed")


# ─────────────────────────────────────────────────────────────────────────
# Pipeline (per file)
# ─────────────────────────────────────────────────────────────────────────

async def process_one(client: httpx.AsyncClient, entry: dict[str, Any]) -> dict[str, Any]:
    file_id = entry["id"]
    filename = entry["filename"]
    if not is_audio(filename):
        await client.post(f"/internal/dropzone/quarantine/{file_id}", json={"reason": f"non-audio: {filename}"})
        return {"file": filename, "status": "quarantined", "reason": "non-audio"}

    suffix = Path(filename).suffix.lower()
    with tempfile.NamedTemporaryFile(prefix="ingest-", suffix=suffix, delete=False) as tmp:
        tmp_path = Path(tmp.name)

    try:
        async with client.stream("GET", f"/internal/dropzone/file/{file_id}", timeout=DOWNLOAD_TIMEOUT) as resp:
            if resp.status_code == 404:
                # File disappeared between list and fetch — fine, skip silently.
                return {"file": filename, "status": "vanished"}
            resp.raise_for_status()
            with tmp_path.open("wb") as fh:
                async for chunk in resp.aiter_bytes(64 * 1024):
                    fh.write(chunk)

        size = tmp_path.stat().st_size
        logger.info("fetched file=%s size=%d", filename, size)

        audio_hash = await compute_audio_hash(tmp_path)
        if audio_hash is not None:
            existing = await INDEX.contains(audio_hash)
            if existing is not None:
                logger.info(
                    "dedup hit file=%s hash=%s existing=%s — acking without ingest",
                    filename, audio_hash, existing,
                )
                ack = await client.post(f"/internal/dropzone/ack/{file_id}", timeout=POLL_TIMEOUT)
                ack.raise_for_status()
                return {
                    "file": filename,
                    "status": "deduped",
                    "hash": audio_hash,
                    "existing": existing,
                }

        tags = read_existing_tags(tmp_path)
        probe = probe_audio(tmp_path)

        try:
            tag_result = await asyncio.to_thread(
                call_llm,
                filename,
                Path(filename).parent.name,
                tags,
                probe.get("duration_s"),
                probe.get("codec"),
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("llm error file=%s", filename)
            await client.post(f"/internal/dropzone/quarantine/{file_id}", json={"reason": f"llm_error: {exc}"})
            return {"file": filename, "status": "failed", "reason": "llm_error"}

        if tag_result.confidence < CONFIDENCE_THRESHOLD or not tag_result.artist or not tag_result.title:
            reason = f"low_confidence={tag_result.confidence:.2f}"
            logger.info("quarantine file=%s reason=%s", filename, reason)
            await client.post(f"/internal/dropzone/quarantine/{file_id}", json={"reason": reason})
            return {"file": filename, "status": "quarantined", "confidence": tag_result.confidence}

        try:
            write_tags(
                tmp_path,
                artist=tag_result.artist,
                title=tag_result.title,
                album=tag_result.album,
                genre=tag_result.genre,
                year=tag_result.year,
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("tag write error file=%s", filename)
            await client.post(f"/internal/dropzone/quarantine/{file_id}", json={"reason": f"tag_write_error: {exc}"})
            return {"file": filename, "status": "failed", "reason": "tag_write_error"}

        final = unique_path(target_path(tag_result.artist, tag_result.title, suffix))
        final.parent.mkdir(parents=True, exist_ok=True)
        # tmp_path is on /tmp (different filesystem), so use shutil.move
        # which falls back to copy+unlink across filesystems.
        shutil.move(str(tmp_path), str(final))
        logger.info(
            "ingested file=%s -> %s artist=%s title=%s confidence=%.2f",
            filename, final.relative_to(MUSIC_PATH), tag_result.artist, tag_result.title, tag_result.confidence,
        )
        if audio_hash is not None:
            await INDEX.add(final, audio_hash)

        ack = await client.post(f"/internal/dropzone/ack/{file_id}", timeout=POLL_TIMEOUT)
        ack.raise_for_status()
        return {
            "file": filename,
            "status": "ingested",
            "artist": tag_result.artist,
            "title": tag_result.title,
            "confidence": tag_result.confidence,
            "final": str(final.relative_to(MUSIC_PATH)),
        }
    finally:
        tmp_path.unlink(missing_ok=True)


# ─────────────────────────────────────────────────────────────────────────
# Poll loop
# ─────────────────────────────────────────────────────────────────────────

@dataclass
class WorkerStats:
    last_poll_at: float = 0.0
    last_listed: int = 0
    total_ingested: int = 0
    total_quarantined: int = 0
    total_deduped: int = 0
    total_errors: int = 0


STATS = WorkerStats()


async def poll_once(client: httpx.AsyncClient) -> None:
    try:
        resp = await client.get("/internal/dropzone/list", timeout=POLL_TIMEOUT)
    except Exception as exc:  # noqa: BLE001
        STATS.total_errors += 1
        logger.warning("poll list failed err=%r", type(exc).__name__)
        return

    STATS.last_poll_at = time.time()
    if resp.status_code != 200:
        STATS.total_errors += 1
        logger.warning("poll list non-200 status=%d", resp.status_code)
        return

    entries = resp.json().get("files", [])
    STATS.last_listed = len(entries)
    if not entries:
        return

    logger.info("poll listed=%d", len(entries))
    for entry in entries:
        try:
            result = await process_one(client, entry)
        except Exception as exc:  # noqa: BLE001
            STATS.total_errors += 1
            logger.exception("process crash file=%s", entry.get("filename"))
            continue
        if result.get("status") == "ingested":
            STATS.total_ingested += 1
        elif result.get("status") == "deduped":
            STATS.total_deduped += 1
        elif result.get("status") in {"quarantined", "failed"}:
            STATS.total_quarantined += 1


async def poll_loop(stop: asyncio.Event) -> None:
    headers = {"Authorization": f"Bearer {INGEST_INTERNAL_TOKEN}"}
    async with httpx.AsyncClient(base_url=INGEST_BASE_URL, headers=headers) as client:
        logger.info(
            "poll loop started base=%s interval=%.0fs model=%s threshold=%.2f",
            INGEST_BASE_URL, POLL_INTERVAL, LITELLM_MODEL, CONFIDENCE_THRESHOLD,
        )
        while not stop.is_set():
            await poll_once(client)
            try:
                await asyncio.wait_for(stop.wait(), timeout=POLL_INTERVAL)
            except asyncio.TimeoutError:
                pass


# ─────────────────────────────────────────────────────────────────────────
# Health server
# ─────────────────────────────────────────────────────────────────────────

async def health(request: web.Request) -> web.Response:
    return web.json_response({
        "ok": True,
        "last_poll_at": STATS.last_poll_at,
        "last_listed": STATS.last_listed,
        "total_ingested": STATS.total_ingested,
        "total_quarantined": STATS.total_quarantined,
        "total_deduped": STATS.total_deduped,
        "total_errors": STATS.total_errors,
        "index_size": INDEX.last_rebuild_size,
        "index_last_rebuild_at": INDEX.last_rebuild_at,
    })


@asynccontextmanager
async def lifespan() -> Any:
    MUSIC_PATH.mkdir(parents=True, exist_ok=True)
    if not INGEST_INTERNAL_TOKEN:
        logger.warning("INGEST_INTERNAL_TOKEN unset — every internal call will return 401")
    if not LITELLM_API_KEY:
        logger.warning("LITELLM_API_KEY unset — LLM calls will fail")
    stop = asyncio.Event()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    # Initial dedup-index rebuild — block until done so the first pull
    # already has a populated map. With an empty library this is ~instant.
    try:
        await INDEX.rebuild()
    except Exception:  # noqa: BLE001
        logger.exception("initial index rebuild failed; continuing with empty index")

    index_task = asyncio.create_task(index_refresh_loop(stop))
    poll_task = asyncio.create_task(poll_loop(stop))

    app = web.Application()
    app.router.add_get("/healthz", health)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", HEALTH_PORT)
    await site.start()

    try:
        yield stop
    finally:
        stop.set()
        try:
            await asyncio.wait_for(poll_task, timeout=10)
        except asyncio.TimeoutError:
            logger.warning("poll loop did not exit within 10s; cancelling")
            poll_task.cancel()
        try:
            await asyncio.wait_for(index_task, timeout=5)
        except asyncio.TimeoutError:
            logger.warning("index refresh loop did not exit within 5s; cancelling")
            index_task.cancel()
        await runner.cleanup()


async def main() -> None:
    async with lifespan() as stop:
        await stop.wait()
    logger.info("shutdown complete")


if __name__ == "__main__":
    asyncio.run(main())
