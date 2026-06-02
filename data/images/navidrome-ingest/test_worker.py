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
    # Default to skip mode; overwrite tests flip it before reload.
    os.environ.setdefault("DUPLICATE_MODE", "skip")
    # Disable yt lookup by default — tests opt in by patching the helper.
    os.environ["YOUTUBE_LOOKUP_ENABLED"] = "false"
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
    # Legacy single-artist payload — back-compat path wraps into list.
    text = 'sure! here:\n{"artist":"X","title":"Y","confidence":0.8}\nthanks'
    tr = worker.parse_tags_from_text(text)
    assert tr.artists == ["X"] and tr.title == "Y" and tr.confidence == 0.8


def test_parse_tags_from_text_handles_artists_list(worker_module):
    worker, _ = worker_module
    text = '{"artists":["A","B"],"title":"T","confidence":0.9}'
    tr = worker.parse_tags_from_text(text)
    assert tr.artists == ["A", "B"]
    assert tr.primary_artist == "A"


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
            # X-Filename header must be ASCII-safe; the real ingest-ui
            # percent-encodes non-ASCII filenames.
            from urllib.parse import quote as _q
            return httpx.Response(200, content=dropzone[n], headers={"X-Filename": _q(n)})
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
        lambda *a, **kw: worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.2),
    )

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert state["quarantined"] and state["quarantined"][0][0] == "weird.opus"
    assert "confidence=0.20" in state["quarantined"][0][1]
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
        lambda *a, **kw: worker.TagResult(artists=["ArtistName"], title="TrackTitle", album=None, genre=None, year=None, confidence=0.9),
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
        lambda *a, **kw: worker.TagResult(artists=["A"], title=a[0][:30], album=None, genre=None, year=None, confidence=0.9),
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
    worker.write_tags(out, artists=["Foo", "Featured"], title="Bar", album=None, genre=None, year="1999")

    h2 = await worker.compute_audio_hash(out)
    assert h2 == h1, "audio-stream md5 must survive tag rewrite"

    # Multi-value artist must round-trip through the file: mutagen reads
    # the FLAC ARTIST comments back as a list.
    from mutagen.flac import FLAC
    f = FLAC(str(out))
    assert list(f["artist"]) == ["Foo", "Featured"]


def test_tag_result_primary_and_display_artist(worker_module):
    worker, _ = worker_module
    tr = worker.TagResult(artists=["A", "B", "C"], title="T", album=None, genre=None, year=None, confidence=0.9)
    assert tr.primary_artist == "A"
    assert tr.display_artist == "A (feat. B, C)"
    solo = worker.TagResult(artists=["Solo"], title="T", album=None, genre=None, year=None, confidence=0.9)
    assert solo.display_artist == "Solo"
    none = worker.TagResult(artists=[], title="T", album=None, genre=None, year=None, confidence=0.9)
    assert none.primary_artist == ""
    assert none.display_artist == ""


def test_tag_result_from_payload_accepts_artists_list(worker_module):
    worker, _ = worker_module
    tr = worker.TagResult.from_payload({"artists": ["A", "B"], "title": "T", "confidence": 0.85})
    assert tr.artists == ["A", "B"]


def test_tag_result_from_payload_legacy_artist_string(worker_module):
    worker, _ = worker_module
    # Old single-string artist still parses (back-compat).
    tr = worker.TagResult.from_payload({"artist": "A", "title": "T", "confidence": 0.85})
    assert tr.artists == ["A"]


def test_tag_result_from_payload_empty_list_when_unknown(worker_module):
    worker, _ = worker_module
    tr = worker.TagResult.from_payload({"artists": [], "title": "Pure Title", "confidence": 0.6})
    assert tr.artists == []
    assert tr.primary_artist == ""


def test_split_combined_artist_handles_common_joiners(worker_module):
    worker, _ = worker_module
    f = worker._split_combined_artist
    assert f("ANIZYZ x Mqx") == ["ANIZYZ", "Mqx"]
    assert f("ANIZYZ x Tevvez x Mqx") == ["ANIZYZ", "Tevvez", "Mqx"]
    assert f("Au5 & Danyka Nadeau") == ["Au5", "Danyka Nadeau"]
    assert f("AmaLee feat. NateWantsToBattle") == ["AmaLee", "NateWantsToBattle"]
    assert f("Au5 (feat. Danyka Nadeau)") == ["Au5", "Danyka Nadeau"]
    assert f("ANDONIS, Tevvez, Sung Jinwoo") == ["ANDONIS", "Tevvez", "Sung Jinwoo"]
    assert f("AmaLee ft. NateWantsToBattle") == ["AmaLee", "NateWantsToBattle"]
    assert f("Solo Artist") == ["Solo Artist"]
    assert f("") == []
    assert f("   ") == []


def test_from_payload_splits_legacy_combined_string(worker_module):
    worker, _ = worker_module
    tr = worker.TagResult.from_payload({"artist": "ANIZYZ x Mqx", "title": "T", "confidence": 0.9})
    assert tr.artists == ["ANIZYZ", "Mqx"]


def test_from_payload_splits_combined_inside_artists_list(worker_module):
    """Model sometimes returns the combined name inside a list — split."""
    worker, _ = worker_module
    tr = worker.TagResult.from_payload({"artists": ["ANDONIS, Tevvez, Sung Jinwoo"], "title": "T", "confidence": 0.9})
    assert tr.artists == ["ANDONIS", "Tevvez", "Sung Jinwoo"]


def test_load_schema_uses_artists_array(worker_module):
    worker, _ = worker_module
    schema = worker.load_schema()
    assert "artists" in schema["properties"]
    assert schema["properties"]["artists"]["type"] == "array"
    assert "artists" in schema["required"]
    assert "artist" not in schema["properties"]


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
        lambda *a, **kw: worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9),
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
        lambda *a, **kw: worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9),
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


# ── DUPLICATE_MODE=overwrite + youtube enrichment ──────────────────────

@pytest.fixture()
def worker_overwrite_mode(tmp_path):
    """Same as worker_module but with DUPLICATE_MODE=overwrite."""
    _set_paths(tmp_path)
    os.environ["DUPLICATE_MODE"] = "overwrite"
    import importlib

    import worker
    importlib.reload(worker)
    yield worker, tmp_path
    # Reset for downstream tests.
    os.environ["DUPLICATE_MODE"] = "skip"


@pytest.mark.asyncio
async def test_dedup_overwrite_in_place_preserves_path(worker_overwrite_mode, monkeypatch):
    """DUPLICATE_MODE=overwrite is in-place: the new file must land at the
    EXISTING library path so Navidrome song IDs (path-keyed) stay stable
    and playlist memberships / play counts / ratings are preserved. The
    on-disk path does NOT change to reflect the new tags."""
    worker, _ = worker_overwrite_mode
    assert worker.DUPLICATE_MODE == "overwrite"

    fake_hash = "f00d" * 8
    old_dir = worker.MUSIC_PATH / "OldArtist"
    old_dir.mkdir()
    old_path = old_dir / "OldTitle.opus"
    old_path.write_bytes(b"old-bytes")
    worker.INDEX._hashes[fake_hash] = "OldArtist/OldTitle.opus"

    dropzone = {"new-tagged-version.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def fake_hash_fn(_p):
        return fake_hash

    async def fake_yt(_q, top_k=3):
        return []

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    monkeypatch.setattr(worker.youtube_lookup, "lookup_youtube", fake_yt)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artists=["NewArtist"], title="NewTitle", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    # File still at the OLD path (in-place overwrite). New computed path
    # for NewArtist/NewTitle does NOT exist on disk.
    assert old_path.exists()
    assert not (worker.MUSIC_PATH / "NewArtist" / "NewTitle.opus").exists()
    # Index path unchanged — still pointing at OldArtist/OldTitle.opus.
    assert worker.INDEX._hashes[fake_hash] == "OldArtist/OldTitle.opus"
    # Dropzone acked.
    assert state["acked"] == ["new-tagged-version.opus"]
    assert not state["quarantined"]
    # Old artist dir survives (file still there).
    assert old_dir.exists()


@pytest.mark.asyncio
async def test_overwrite_in_place_works_when_llm_picks_same_artist(worker_overwrite_mode, monkeypatch):
    """In-place overwrite where the LLM produces the SAME artist as the
    existing entry. Same path stays the same path."""
    worker, _ = worker_overwrite_mode

    fake_hash = "1234" * 8
    artist_dir = worker.MUSIC_PATH / "AmaLee"
    artist_dir.mkdir()
    old_path = artist_dir / "OldName.opus"
    old_path.write_bytes(b"old")
    worker.INDEX._hashes[fake_hash] = "AmaLee/OldName.opus"

    dropzone = {"new.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def fake_hash_fn(_p):
        return fake_hash

    async def fake_yt(_q, top_k=3):
        return []

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    monkeypatch.setattr(worker.youtube_lookup, "lookup_youtube", fake_yt)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artists=["AmaLee"], title="NewName", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    # In-place: file stays at OldName.opus path even though LLM said
    # NewName. Tag will reflect "NewName"; on-disk filename will not.
    assert old_path.exists()
    assert not (worker.MUSIC_PATH / "AmaLee" / "NewName.opus").exists()
    assert artist_dir.exists()
    assert worker.INDEX._hashes[fake_hash] == "AmaLee/OldName.opus"
    assert state["acked"] == ["new.opus"]


@pytest.mark.asyncio
async def test_overwrite_with_old_file_already_missing_is_ok(worker_overwrite_mode, monkeypatch):
    """If the index points at a file that was manually removed since the
    last rebuild, in-place overwrite must still place the new file at the
    indexed path (mkdir parent if needed) and not crash."""
    worker, _ = worker_overwrite_mode

    fake_hash = "abcd" * 8
    # Seed an index pointing at a path that doesn't exist on disk.
    worker.INDEX._hashes[fake_hash] = "Phantom/Gone.opus"

    dropzone = {"replacement.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def fake_hash_fn(_p):
        return fake_hash

    async def fake_yt(_q, top_k=3):
        return []

    monkeypatch.setattr(worker, "compute_audio_hash", fake_hash_fn)
    monkeypatch.setattr(worker.youtube_lookup, "lookup_youtube", fake_yt)
    monkeypatch.setattr(
        worker,
        "call_llm",
        lambda *a, **kw: worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9),
    )
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    # New file placed at the recorded path (Phantom/Gone.opus), not at
    # the LLM-derived target (A/T.opus). In-place semantics.
    placed = worker.MUSIC_PATH / "Phantom" / "Gone.opus"
    assert placed.exists()
    assert worker.INDEX._hashes[fake_hash] == "Phantom/Gone.opus"
    assert state["acked"] == ["replacement.opus"]


@pytest.mark.asyncio
async def test_youtube_hits_passed_to_call_llm(worker_module, monkeypatch):
    """The yt-lookup result must reach call_llm as the 6th positional arg
    (filename, parent_dir, tags, duration_s, codec, youtube_hits)."""
    worker, _ = worker_module
    dropzone = {"track.opus": b"\x00\x00\x00"}
    transport, state = _build_server(worker, dropzone)

    async def _no_hash(_p):
        return None

    fake_hits = [{"title": "T", "uploader": "U", "channel": "C", "description": "", "tags": [], "categories": [], "duration": 200, "webpage_url": "u"}]

    async def fake_yt(_q, top_k=3):
        return fake_hits

    seen_args: list = []

    def fake_call_llm(*a, **kw):
        seen_args.append(a)
        return worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9)

    monkeypatch.setattr(worker, "compute_audio_hash", _no_hash)
    monkeypatch.setattr(worker.youtube_lookup, "lookup_youtube", fake_yt)
    monkeypatch.setattr(worker, "call_llm", fake_call_llm)
    monkeypatch.setattr(worker, "write_tags", lambda *a, **kw: None)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert seen_args, "call_llm was not invoked"
    a = seen_args[0]
    assert a[0] == "track.opus"           # filename
    assert a[5] == fake_hits              # youtube_hits


@pytest.mark.asyncio
async def test_call_llm_renders_no_matches_when_yt_empty(worker_module, monkeypatch):
    """call_llm must render the youtube_hits jinja var as '(no matches)'
    when an empty list is passed; downstream prompt has rules for that."""
    worker, _ = worker_module

    captured: dict = {}

    def fake_render_completion(*, routed_model, messages, schema, use_tool_call):
        captured["user"] = messages[-1]["content"]
        return worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9)

    monkeypatch.setattr(worker, "_try_completion", fake_render_completion)

    worker.call_llm("foo.opus", "parent", {}, 200, "Opus", youtube_hits=[])
    assert "(no matches)" in captured["user"]


@pytest.mark.asyncio
async def test_call_llm_renders_yt_block_when_present(worker_module, monkeypatch):
    worker, _ = worker_module
    captured: dict = {}

    def fake_render_completion(*, routed_model, messages, schema, use_tool_call):
        captured["user"] = messages[-1]["content"]
        return worker.TagResult(artists=["A"], title="T", album=None, genre=None, year=None, confidence=0.9)

    monkeypatch.setattr(worker, "_try_completion", fake_render_completion)

    hits = [{"title": "MyTrack", "uploader": "MyChannel", "channel": "MyChannel"}]
    worker.call_llm("foo.opus", "parent", {}, 200, "Opus", youtube_hits=hits)
    assert "MyTrack" in captured["user"]
    assert "MyChannel" in captured["user"]
    assert "(no matches)" not in captured["user"]


# ── Concurrency ────────────────────────────────────────────────────────

@pytest.fixture()
def worker_concurrency_limit_3(tmp_path, monkeypatch):
    """Reload worker with INGEST_CONCURRENCY=3 so we can verify the
    semaphore caps in-flight processing."""
    _set_paths(tmp_path)
    monkeypatch.setenv("INGEST_CONCURRENCY", "3")
    import importlib

    import worker
    importlib.reload(worker)
    return worker, tmp_path


@pytest.mark.asyncio
async def test_poll_once_caps_in_flight_at_concurrency_limit(worker_concurrency_limit_3, monkeypatch):
    """Spawn many dropzone entries; assert at no point are more than
    INGEST_CONCURRENCY process_one calls in flight simultaneously."""
    import asyncio

    worker, _ = worker_concurrency_limit_3
    assert worker.INGEST_CONCURRENCY == 3

    n_entries = 12
    dropzone = {f"track-{i:02d}.opus": b"\x00\x00\x00" for i in range(n_entries)}
    transport, state = _build_server(worker, dropzone)

    in_flight = 0
    peak = 0
    enter = asyncio.Event()

    async def fake_process_one(_client, entry):
        nonlocal in_flight, peak
        in_flight += 1
        peak = max(peak, in_flight)
        # Yield so all gated tasks queue up before any completes.
        await asyncio.sleep(0.02)
        in_flight -= 1
        return {"file": entry["filename"], "status": "ingested"}

    monkeypatch.setattr(worker, "process_one", fake_process_one)

    async with httpx.AsyncClient(
        transport=transport,
        base_url="http://ingest-fake/",
        headers={"Authorization": "Bearer tok"},
    ) as client:
        await worker.poll_once(client)

    assert peak <= 3, f"in-flight peak={peak} exceeded concurrency=3"
    # All entries finished — peak hit the cap on a 12-of-3 run.
    assert peak == 3, f"expected peak=3 with 12 entries / concurrency 3, got {peak}"
    assert worker.STATS.last_listed == n_entries
