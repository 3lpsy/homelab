"""Unit tests for navidrome-ingest worker (poll-based pull client).

Run locally:
    cd data/images/navidrome-ingest
    uv run --group dev pytest test_worker.py -v
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import httpx
import pytest


def _set_paths(tmp_path: Path) -> Path:
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    os.environ["MUSIC_PATH"] = str(music)
    os.environ["LITELLM_API_KEY"] = "fake"
    os.environ["LITELLM_BASE_URL"] = "http://fake/"
    os.environ["INGEST_BASE_URL"] = "http://ingest-fake/"
    os.environ["INGEST_INTERNAL_TOKEN"] = "tok"
    return music


@pytest.fixture()
def worker_module(tmp_path):
    _set_paths(tmp_path)
    import importlib

    import worker

    importlib.reload(worker)
    return worker, tmp_path


# ── Pure helpers ────────────────────────────────────────────────────────

def test_sanitize_path_segment(worker_module):
    worker, _ = worker_module
    assert worker.sanitize_path_segment("Artist/Name") == "Artist_Name"
    assert worker.sanitize_path_segment("trailing dots...") == "trailing dots"
    assert worker.sanitize_path_segment("\x00bad\x01") == "bad"
    assert worker.sanitize_path_segment("") == "unknown"
    assert worker.sanitize_path_segment("   ") == "unknown"


def test_sanitize_path_segment_nfkc_fullwidth(worker_module):
    worker, _ = worker_module
    # Fullwidth quotation mark and pipe should normalize to ASCII.
    assert worker.sanitize_path_segment("＂RISE＂") == "RISE"  # quotes themselves stripped (FS-reserved)
    # Fullwidth pipe stripped because | is FS-reserved on Windows.
    assert worker.sanitize_path_segment("a｜b") == "ab"
    # Normal latin diacritics preserved.
    assert worker.sanitize_path_segment("Café Tacuba") == "Café Tacuba"


def test_sanitize_path_segment_strips_fs_reserved(worker_module):
    worker, _ = worker_module
    assert worker.sanitize_path_segment("foo<bar>baz") == "foobarbaz"
    assert worker.sanitize_path_segment('foo"bar') == "foobar"
    assert worker.sanitize_path_segment("a*b?c:d") == "abcd"


def test_target_path_layout(worker_module):
    worker, _ = worker_module
    p = worker.target_path("Wejoell", "Animal I Have Become", ".opus")
    assert p.parent.name == "Wejoell"
    assert p.name == "Animal I Have Become.opus"
    assert p.is_relative_to(worker.MUSIC_PATH)


def test_unique_path_appends_suffix_when_collision(worker_module):
    worker, _ = worker_module
    artist = worker.MUSIC_PATH / "X"
    artist.mkdir(parents=True, exist_ok=True)
    existing = artist / "song.opus"
    existing.write_bytes(b"already")
    new = worker.unique_path(artist / "song.opus")
    assert new != existing
    assert new.parent == artist
    assert new.suffix == ".opus"
    assert new.stem.startswith("song-")


def test_is_audio_filter(worker_module):
    worker, _ = worker_module
    assert worker.is_audio("a.opus")
    assert worker.is_audio("a.OPUS")
    assert worker.is_audio("a.flac")
    assert not worker.is_audio("a.txt")


def test_parse_tags_from_text_extracts_json(worker_module):
    worker, _ = worker_module
    text = 'sure! here:\n{"artist":"X","title":"Y","confidence":0.8}\nthanks'
    tr = worker.parse_tags_from_text(text)
    assert tr.artist == "X" and tr.title == "Y" and tr.confidence == 0.8


def test_parse_tags_from_text_returns_zero_on_garbage(worker_module):
    worker, _ = worker_module
    assert worker.parse_tags_from_text("not json").confidence == 0.0


def test_tag_result_from_payload_handles_optional_fields(worker_module):
    worker, _ = worker_module
    tr = worker.TagResult.from_payload({"artist": "A", "title": "T", "confidence": 0.7})
    assert tr.album is None and tr.genre is None and tr.year is None
    tr2 = worker.TagResult.from_payload({"artist": "A", "title": "T", "album": "", "confidence": 0.5})
    assert tr2.album is None


def test_load_schema_default_shape(worker_module):
    worker, _ = worker_module
    schema = worker.load_schema()
    assert schema["type"] == "object"
    assert "confidence" in schema["properties"]


# ── HTTP client integration via httpx MockTransport ────────────────────

def _build_server(worker, dropzone: dict[str, bytes]) -> httpx.MockTransport:
    """Build a MockTransport that simulates ingest-ui /internal/* endpoints.

    `dropzone` is a mutable dict {filename: bytes}. ack/quarantine remove
    entries; list/file read them.
    """
    quarantined: list[tuple[str, str]] = []
    acked: list[str] = []
    state = {"quarantined": quarantined, "acked": acked}

    def file_id(name: str) -> str:
        # Match worker's file_id_for relative computation: rel = music/<name>.
        # But the worker uses ingest-ui's file_id_for which includes the
        # `music/` prefix. We just round-trip whatever the server returns.
        import base64
        import hashlib

        digest = hashlib.sha1(f"music/{name}".encode("utf-8")).digest()
        return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()

    name_by_id = lambda fid: next((n for n in dropzone if file_id(n) == fid), None)  # noqa: E731

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.headers.get("authorization") != "Bearer tok":
            return httpx.Response(401, json={"detail": "unauthorized"})
        if path == "/internal/dropzone/list":
            files = [
                {"id": file_id(n), "filename": n, "size": len(b), "mtime": 0.0}
                for n, b in dropzone.items()
            ]
            return httpx.Response(200, json={"files": files})
        if path.startswith("/internal/dropzone/file/"):
            fid = path.rsplit("/", 1)[-1]
            n = name_by_id(fid)
            if n is None:
                return httpx.Response(404)
            return httpx.Response(200, content=dropzone[n], headers={"X-Filename": n})
        if path.startswith("/internal/dropzone/ack/"):
            fid = path.rsplit("/", 1)[-1]
            n = name_by_id(fid)
            if n is None:
                return httpx.Response(404)
            del dropzone[n]
            acked.append(n)
            return httpx.Response(200, json={"acked": n})
        if path.startswith("/internal/dropzone/quarantine/"):
            fid = path.rsplit("/", 1)[-1]
            n = name_by_id(fid)
            if n is None:
                return httpx.Response(404)
            body = json.loads(request.content.decode() or "{}")
            del dropzone[n]
            quarantined.append((n, body.get("reason", "")))
            return httpx.Response(200, json={"quarantined": n, "reason": body.get("reason")})
        return httpx.Response(404)

    transport = httpx.MockTransport(handler)
    return transport, state


@pytest.mark.asyncio
async def test_poll_once_quarantines_low_confidence(worker_module, monkeypatch):
    worker, _ = worker_module
    dropzone = {"weird.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def _no_hash(_p):
        return None
    monkeypatch.setattr(worker, "compute_audio_hash", _no_hash)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artist="A", title="T", album=None, genre=None, year=None, confidence=0.2),
    )

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["quarantined"] and state["quarantined"][0][0] == "weird.opus"
    assert "low_confidence" in state["quarantined"][0][1]
    assert not state["acked"]


@pytest.mark.asyncio
async def test_poll_once_ingests_high_confidence(worker_module, monkeypatch):
    worker, _ = worker_module
    dropzone = {"good.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def _no_hash(_p):
        return None
    monkeypatch.setattr(worker, "compute_audio_hash", _no_hash)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artist="ArtistName", title="TrackTitle", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["acked"] == ["good.opus"]
    assert not state["quarantined"]
    # File landed under /music/<artist>/<title>.<ext>
    final = worker.MUSIC_PATH / "ArtistName" / "TrackTitle.opus"
    assert final.exists()


@pytest.mark.asyncio
async def test_poll_once_quarantines_non_audio(worker_module, monkeypatch):
    worker, _ = worker_module
    dropzone = {"readme.txt": b"hello"}
    transport, state = _build_server(worker, dropzone)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["quarantined"] and state["quarantined"][0][0] == "readme.txt"
    assert "non-audio" in state["quarantined"][0][1]


@pytest.mark.asyncio
async def test_poll_once_handles_real_corpus_filenames(worker_module, monkeypatch):
    """Smoke test: a representative sample of YouTube-edit filenames from the
    user's actual corpus. Pipeline must pull, tag, write, ack each one cleanly."""
    worker, _ = worker_module
    samples = [
        "Wejoell x Tr3n Motivation ｜ Animal I Have Become- (Tren Twins Edit).opus",
        "ZYZZ ｜ SEREBO - MALO TEBYA ｜ - (HARDSTYLE).opus",
        "if it means winning..opus",
        "“You Decide” - by ANIZYZ (feat. Stef Meyers).opus",
    ]
    dropzone = {n: b"\x00\x00\x00" for n in samples}
    transport, state = _build_server(worker, dropzone)

    async def _no_hash(_p):
        return None
    monkeypatch.setattr(worker, "compute_audio_hash", _no_hash)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artist="A", title=a[0][:30], album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert sorted(state["acked"]) == sorted(samples)


@pytest.mark.asyncio
async def test_poll_once_recovers_from_list_error(worker_module):
    worker, _ = worker_module

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503)

    async with httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        # Should not raise — should record error and return.
        await worker.poll_once(client)

    assert worker.STATS.total_errors >= 1


@pytest.mark.asyncio
async def test_poll_once_skips_when_list_empty(worker_module):
    worker, _ = worker_module

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"files": []})

    async with httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    # No work, no errors
    assert worker.STATS.last_listed == 0


# ── Dedup index ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_compute_audio_hash_returns_none_on_garbage(worker_module, tmp_path):
    """PyAV invocation against a non-audio blob — must return None, not
    raise."""
    worker, _ = worker_module
    bogus = tmp_path / "bogus.opus"
    bogus.write_bytes(b"\x00" * 64)
    h = await worker.compute_audio_hash(bogus)
    assert h is None


@pytest.mark.asyncio
async def test_compute_audio_hash_stable_across_tag_rewrite(worker_module, tmp_path):
    """Round-trip: encode a tiny silent FLAC, hash it, rewrite tags via
    mutagen, hash again — both hashes must match because the audio
    packet stream didn't change."""
    import av as _av  # noqa: F401  — proves PyAV importable
    worker, _ = worker_module

    # Encode 0.1s of silence to FLAC. PyAV requires a frame; use a
    # one-channel s16 frame of zeros.
    out = tmp_path / "silence.flac"
    container = _av.open(str(out), mode="w")
    try:
        stream = container.add_stream("flac", rate=44100)
        stream.layout = "mono"
        # Build a small audio frame of silence.
        import numpy as np
        samples = np.zeros((1, 4410), dtype=np.int16)  # 0.1s mono
        frame = _av.AudioFrame.from_ndarray(samples, format="s16", layout="mono")
        frame.rate = 44100
        for packet in stream.encode(frame):
            container.mux(packet)
        for packet in stream.encode(None):
            container.mux(packet)
    finally:
        container.close()

    h1 = await worker.compute_audio_hash(out)
    assert h1 is not None

    # Rewrite tags via the worker's own write_tags helper.
    worker.write_tags(out, artist="Foo", title="Bar", album=None, genre=None, year="1999")

    h2 = await worker.compute_audio_hash(out)
    assert h2 == h1, "audio-stream md5 must survive tag rewrite"


@pytest.mark.asyncio
async def test_dedup_hit_acks_without_llm_call(worker_module, monkeypatch):
    """If the audio-stream md5 already exists in the library index, the
    worker must ack the dropzone file (treated as success), skip LLM +
    tag-write, and bump total_deduped."""
    worker, _ = worker_module
    dropzone = {"already-have-this.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    fake_hash = "deadbeefdeadbeefdeadbeefdeadbeef"

    async def fake_hash_fn(_path):
        return fake_hash

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    # Seed the index with the same hash → dedup must trigger.
    worker.INDEX._hashes[fake_hash] = "Existing/Track.opus"

    llm_called = False

    def boom(**_kw):
        nonlocal llm_called
        llm_called = True
        raise AssertionError("call_llm must not run on dedup hit")

    monkeypatch.setattr(worker, "call_llm", boom)
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    before = worker.STATS.total_deduped

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["acked"] == ["already-have-this.opus"]
    assert not state["quarantined"]
    assert not llm_called
    assert worker.STATS.total_deduped == before + 1


@pytest.mark.asyncio
async def test_dedup_miss_ingests_and_inserts_into_index(worker_module, monkeypatch):
    """Hash miss must proceed through normal pipeline and insert the new
    file's hash into the index so a re-pull is then deduped."""
    worker, _ = worker_module
    dropzone = {"new-track.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    fake_hash = "abc123abc123abc123abc123abc12300"

    async def fake_hash_fn(_path):
        return fake_hash

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artist="A", title="T", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    assert fake_hash not in worker.INDEX._hashes

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["acked"] == ["new-track.opus"]
    assert fake_hash in worker.INDEX._hashes
    assert worker.INDEX._hashes[fake_hash].endswith("T.opus")


@pytest.mark.asyncio
async def test_dedup_skipped_when_hash_compute_fails(worker_module, monkeypatch):
    """If ffmpeg fails (returns None) the worker must NOT block the file —
    it should fall through to the normal LLM + write path. Index is not
    updated since we have no key."""
    worker, _ = worker_module
    dropzone = {"unhashable.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def fake_hash_fn(_path):
        return None

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artist="A", title="T", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    snapshot = dict(worker.INDEX._hashes)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["acked"] == ["unhashable.opus"]
    assert worker.INDEX._hashes == snapshot  # nothing added


@pytest.mark.asyncio
async def test_library_index_rebuild_walks_root(worker_module, monkeypatch):
    """Rebuild must walk the music root, hash each audio file, replace the
    map atomically, and ignore non-audio."""
    worker, _ = worker_module
    music = worker.MUSIC_PATH
    (music / "Artist").mkdir()
    (music / "Artist" / "song.opus").write_bytes(b"x")
    (music / "Artist" / "notes.txt").write_bytes(b"ignore me")
    (music / "Artist" / "track.flac").write_bytes(b"y")

    seen: list[str] = []

    async def fake_hash_fn(path):
        seen.append(path.name)
        return f"hash-{path.name}"

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)

    await worker.INDEX.rebuild()

    assert sorted(seen) == ["song.opus", "track.flac"]
    assert worker.INDEX.last_rebuild_size == 2
    assert any(p.endswith("song.opus") for p in worker.INDEX._hashes.values())
