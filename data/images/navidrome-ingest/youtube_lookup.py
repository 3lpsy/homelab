"""YouTube metadata enrichment for the navidrome-ingest worker.

Most files arrive named after their YouTube source title (yt-dlp's default
`%(title)s.%(ext)s` template). The filename alone is often too noisy for
the LLM to parse cleanly. This module searches YouTube for the same
string, returns top-K results' metadata (uploader/channel/description/
tags), and the worker passes that through to the prompt as additional
context.

Design notes:
  - All HTTP goes through the cluster's exitnode-haproxy by default so we
    rotate egress IPs and don't get rate-limited from a single source.
  - Retries with exponential backoff. 429 + "Sign in to confirm you're
    not a bot" responses are flagged distinctly in logs.
  - Failures are swallowed: the worker treats enrichment as best-effort.
    A failed lookup returns [] and the LLM tags from filename alone, the
    same as today.
  - YOUTUBE_LOOKUP_ENABLED=false short-circuits before any network call.
"""
from __future__ import annotations

import asyncio
import logging
import os
import random
from typing import Any

logger = logging.getLogger("navidrome-ingest.yt")

# ─────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────

YOUTUBE_LOOKUP_ENABLED = os.environ.get("YOUTUBE_LOOKUP_ENABLED", "true").lower() == "true"
YOUTUBE_PROXY_URL = os.environ.get(
    "YOUTUBE_PROXY_URL",
    "http://exitnode-haproxy.exitnode.svc.cluster.local:8888",
)
YT_LOOKUP_TIMEOUT = float(os.environ.get("YT_LOOKUP_TIMEOUT", "20"))
YT_LOOKUP_RETRIES = int(os.environ.get("YT_LOOKUP_RETRIES", "6"))
YT_DESCRIPTION_CHARS = int(os.environ.get("YT_DESCRIPTION_CHARS", "1500"))
YT_MAX_TAGS = int(os.environ.get("YT_MAX_TAGS", "20"))


_IP_BLOCK_MARKERS = (
    "sign in to confirm",
    "confirm you're not a bot",
    "http error 429",
    "too many requests",
)


def _looks_like_ip_block(message: str) -> bool:
    m = (message or "").lower()
    return any(marker in m for marker in _IP_BLOCK_MARKERS)


def _trim_entry(entry: dict[str, Any]) -> dict[str, Any]:
    """Project a yt-dlp entry down to the fields the LLM actually needs."""
    desc = entry.get("description") or ""
    if isinstance(desc, str) and len(desc) > YT_DESCRIPTION_CHARS:
        desc = desc[:YT_DESCRIPTION_CHARS] + "…"
    tags = entry.get("tags") or []
    if isinstance(tags, list) and len(tags) > YT_MAX_TAGS:
        tags = tags[:YT_MAX_TAGS]
    return {
        "title": entry.get("title"),
        "uploader": entry.get("uploader"),
        "channel": entry.get("channel"),
        "description": desc,
        "tags": tags,
        "categories": entry.get("categories") or [],
        "duration": entry.get("duration"),
        "webpage_url": entry.get("webpage_url"),
    }


def _blocking_search(query: str, top_k: int) -> list[dict[str, Any]]:
    """Run yt-dlp ytsearch in the calling thread. Caller dispatches via
    asyncio.to_thread so the event loop stays responsive."""
    # Local import — yt_dlp is heavy and not needed when lookup is disabled.
    from yt_dlp import YoutubeDL  # type: ignore[import-not-found]
    from yt_dlp.utils import DownloadError  # type: ignore[import-not-found]

    opts: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "extract_flat": False,
        "noplaylist": False,
        "socket_timeout": max(5, int(YT_LOOKUP_TIMEOUT // 2)),
        "default_search": f"ytsearch{top_k}",
    }
    if YOUTUBE_PROXY_URL:
        opts["proxy"] = YOUTUBE_PROXY_URL

    with YoutubeDL(opts) as ydl:
        try:
            info = ydl.extract_info(query, download=False, process=True)
        except DownloadError as e:
            # Re-raise with a tagged message so the async wrapper can
            # tell IP-block from generic failure.
            raise RuntimeError(f"yt-dlp DownloadError: {e}") from e

    if not info:
        return []
    entries = info.get("entries") if isinstance(info, dict) else None
    if not entries:
        return []
    return [_trim_entry(e) for e in entries if isinstance(e, dict)]


async def lookup_youtube(query: str, *, top_k: int = 3) -> list[dict[str, Any]]:
    """Search YouTube for ``query`` and return up to ``top_k`` trimmed
    metadata dicts. Returns [] on disable, no-match, or unrecoverable
    failure — the caller should treat enrichment as best-effort.
    """
    if not YOUTUBE_LOOKUP_ENABLED:
        return []
    if not query.strip():
        return []
    if top_k <= 0:
        return []

    # ytsearch query syntax: yt-dlp accepts the bare string when
    # default_search is set. We pass the query as-is; yt-dlp normalizes.
    last_err: str | None = None
    for attempt in range(1, YT_LOOKUP_RETRIES + 1):
        try:
            hits = await asyncio.wait_for(
                asyncio.to_thread(_blocking_search, query, top_k),
                timeout=YT_LOOKUP_TIMEOUT,
            )
            if hits:
                summary = "; ".join(
                    f"{(h.get('title') or '')[:60]} (by {h.get('uploader') or h.get('channel') or '?'})"
                    for h in hits
                )
                logger.info(
                    "yt lookup hits=%d query=%s top=[%s]",
                    len(hits), query[:120], summary[:400],
                )
            else:
                logger.info("yt lookup no-match query=%s", query[:120])
            return hits
        except asyncio.TimeoutError:
            last_err = "timeout"
            logger.warning("yt lookup timeout attempt=%d query=%s", attempt, query[:120])
        except Exception as exc:  # noqa: BLE001
            last_err = str(exc)
            if _looks_like_ip_block(last_err):
                logger.warning(
                    "yt lookup ip-block attempt=%d query=%s err=%s",
                    attempt, query[:120], last_err[:200],
                )
            else:
                logger.warning(
                    "yt lookup error attempt=%d query=%s err=%s",
                    attempt, query[:120], last_err[:200],
                )

        if attempt < YT_LOOKUP_RETRIES:
            backoff = min(30.0, (2 ** (attempt - 1)) + random.uniform(0, 1))
            await asyncio.sleep(backoff)

    logger.warning("yt lookup giving up query=%s last_err=%s", query[:120], (last_err or "")[:200])
    return []
