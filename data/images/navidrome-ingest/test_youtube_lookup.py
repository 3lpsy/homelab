"""Tests for the YouTube enrichment helper.

Run locally:
    cd data/images/navidrome-ingest
    uv run --group dev pytest test_youtube_lookup.py -v
"""
from __future__ import annotations

import os

import pytest


@pytest.fixture()
def yt_module(monkeypatch):
    """Reload youtube_lookup with a clean env. Tests can monkeypatch
    module-level constants after import."""
    monkeypatch.setenv("YOUTUBE_LOOKUP_ENABLED", "true")
    monkeypatch.setenv("YT_LOOKUP_RETRIES", "3")
    monkeypatch.setenv("YT_LOOKUP_TIMEOUT", "5")
    monkeypatch.setenv("YOUTUBE_PROXY_URL", "http://proxy:8888")
    import importlib

    import youtube_lookup as yl
    importlib.reload(yl)
    return yl


# ── Pure helpers ────────────────────────────────────────────────────────

def test_looks_like_ip_block_recognizes_429(yt_module):
    assert yt_module._looks_like_ip_block("HTTP Error 429: Too Many Requests")
    assert yt_module._looks_like_ip_block("Sign in to confirm you're not a bot")
    assert not yt_module._looks_like_ip_block("connection refused")
    assert not yt_module._looks_like_ip_block("")


def test_trim_entry_truncates_description_and_tags(yt_module, monkeypatch):
    monkeypatch.setattr(yt_module, "YT_DESCRIPTION_CHARS", 50)
    monkeypatch.setattr(yt_module, "YT_MAX_TAGS", 3)
    entry = {
        "title": "Some Title",
        "uploader": "Uploader",
        "channel": "Channel",
        "description": "x" * 200,
        "tags": ["a", "b", "c", "d", "e"],
        "categories": ["Music"],
        "duration": 215,
        "webpage_url": "https://youtube.com/watch?v=abc",
        "extra_field": "should not appear",
    }
    out = yt_module._trim_entry(entry)
    assert len(out["description"]) == 51  # 50 chars + ellipsis
    assert out["description"].endswith("…")
    assert out["tags"] == ["a", "b", "c"]
    assert out["title"] == "Some Title"
    assert "extra_field" not in out


def test_trim_entry_handles_missing_fields(yt_module):
    out = yt_module._trim_entry({})
    assert out == {
        "title": None,
        "uploader": None,
        "channel": None,
        "description": "",
        "tags": [],
        "categories": [],
        "duration": None,
        "webpage_url": None,
    }


# ── Async surface ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_lookup_returns_empty_when_disabled(yt_module, monkeypatch):
    monkeypatch.setattr(yt_module, "YOUTUBE_LOOKUP_ENABLED", False)
    called = False

    def boom(*_a, **_kw):
        nonlocal called
        called = True
        raise AssertionError("must not run when disabled")

    monkeypatch.setattr(yt_module, "_blocking_search", boom)
    out = await yt_module.lookup_youtube("anything")
    assert out == []
    assert called is False


@pytest.mark.asyncio
async def test_lookup_empty_query_returns_empty(yt_module):
    assert await yt_module.lookup_youtube("") == []
    assert await yt_module.lookup_youtube("   ") == []


@pytest.mark.asyncio
async def test_lookup_top_k_zero_returns_empty(yt_module):
    assert await yt_module.lookup_youtube("foo", top_k=0) == []


@pytest.mark.asyncio
async def test_lookup_returns_hits_on_success(yt_module, monkeypatch):
    fake_hits = [
        {"title": "T1", "uploader": "U1", "channel": "C1", "description": "", "tags": [], "categories": [], "duration": 100, "webpage_url": "u1"},
        {"title": "T2", "uploader": "U2", "channel": "C2", "description": "", "tags": [], "categories": [], "duration": 110, "webpage_url": "u2"},
    ]
    monkeypatch.setattr(yt_module, "_blocking_search", lambda q, k: fake_hits)
    out = await yt_module.lookup_youtube("some song", top_k=2)
    assert out == fake_hits


@pytest.mark.asyncio
async def test_lookup_retries_then_falls_through(yt_module, monkeypatch):
    """Generic transient failure: each attempt raises, lookup returns []
    after YT_LOOKUP_RETRIES attempts and never raises to caller."""
    attempts = 0

    def boom(_q, _k):
        nonlocal attempts
        attempts += 1
        raise RuntimeError("yt-dlp DownloadError: ERROR: Unable to extract")

    monkeypatch.setattr(yt_module, "_blocking_search", boom)
    # No real backoff during tests.
    monkeypatch.setattr(yt_module.asyncio, "sleep", lambda *_a, **_kw: _aiosleep_noop())

    out = await yt_module.lookup_youtube("query")
    assert out == []
    assert attempts == yt_module.YT_LOOKUP_RETRIES


@pytest.mark.asyncio
async def test_lookup_ip_block_logged_distinctly(yt_module, monkeypatch, caplog):
    """When the failure message looks like an IP block, the warning log
    should mention 'ip-block' so we can tell it apart from generic errors."""
    import logging as _logging

    def boom(_q, _k):
        raise RuntimeError("yt-dlp DownloadError: HTTP Error 429: Too Many Requests")

    monkeypatch.setattr(yt_module, "_blocking_search", boom)
    monkeypatch.setattr(yt_module.asyncio, "sleep", lambda *_a, **_kw: _aiosleep_noop())

    caplog.set_level(_logging.WARNING, logger="navidrome-ingest.yt")
    out = await yt_module.lookup_youtube("query")
    assert out == []
    assert any("ip-block" in r.getMessage() for r in caplog.records)


# Helper: a real awaitable that returns immediately, used to short-circuit
# asyncio.sleep without monkeypatching the whole asyncio module. The
# monkeypatches above replace `yt_module.asyncio.sleep` with this getter.
async def _aiosleep_noop():
    return None
