"""Unit tests for the ingest-ui FastAPI service.

Run locally:
    cd data/images/ingest-ui
    pip install fastapi pytest httpx python-multipart starlette uvicorn yt-dlp pydantic
    python -m pytest test_server.py -v
"""
from __future__ import annotations

import io
import os
import threading
import zipfile
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient


def _set_env(tmp_path: Path) -> None:
    os.environ["DROPZONE_PATH"] = str(tmp_path)
    os.environ["EXITNODE_PROXIES"] = (
        "http://exitnode-a-proxy.exitnode.svc.cluster.local:8888 "
        "http://exitnode-b-proxy.exitnode.svc.cluster.local:8888"
    )
    os.environ["INGEST_INTERNAL_TOKEN"] = "test-token-xyz"


@pytest.fixture()
def app_client(tmp_path, monkeypatch):
    _set_env(tmp_path)
    import importlib

    import server

    importlib.reload(server)
    return server, TestClient(server.app), tmp_path


# ── Public + auth-bypassing surface ─────────────────────────────────────

def test_healthz_reports_proxy_count_and_internal_auth(app_client):
    server, client, _ = app_client
    with client:
        r = client.get("/healthz")
        assert r.status_code == 200
        body = r.json()
        assert body["ok"] is True
        assert body["exit_proxies"] == 2
        assert body["internal_auth_configured"] is True


def test_index_html_served(app_client):
    server, client, _ = app_client
    with client:
        r = client.get("/")
        assert r.status_code == 200
        assert b"<h1>ingest</h1>" in r.content


# ── Helpers ─────────────────────────────────────────────────────────────

def test_sanitize_filename_blocks_path_traversal(app_client):
    server, _, _ = app_client
    assert server.sanitize_filename("../../etc/passwd") == "_.._.._etc_passwd".replace("_..", "_..")
    assert server.sanitize_filename("good name.opus") == "good name.opus"
    assert server.sanitize_filename("\x00bad\x01.mp3") == "bad.mp3"
    assert server.sanitize_filename("") == "unnamed"
    assert server.sanitize_filename("...secret") == "secret"


# ── DownloadOptions Pydantic model ──────────────────────────────────────

def test_download_options_minimum_payload(app_client):
    server, _, _ = app_client
    opts = server.DownloadOptions(url="https://youtu.be/abc")
    assert str(opts.url).startswith("https://youtu.be/abc")
    assert opts.target == "music"
    assert opts.audio_only is True
    assert opts.no_playlist is True
    assert opts.format is None


def test_download_options_rejects_unknown_field(app_client):
    server, _, _ = app_client
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        server.DownloadOptions(url="https://youtu.be/abc", custom_args=["--exec", "rm -rf /"])


def test_download_options_rejects_non_http_url(app_client):
    server, _, _ = app_client
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        server.DownloadOptions(url="ftp://x")


def test_download_options_bounds_int_fields(app_client):
    server, _, _ = app_client
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        server.DownloadOptions(url="https://youtu.be/abc", playlist_end=0)
    with pytest.raises(ValidationError):
        server.DownloadOptions(url="https://youtu.be/abc", max_filesize_mb=99999)
    with pytest.raises(ValidationError):
        server.DownloadOptions(url="https://youtu.be/abc", max_downloads=0)


def test_download_options_format_charset(app_client):
    server, _, _ = app_client
    safe = server.DownloadOptions(url="https://youtu.be/abc", format="bestaudio[ext=opus]")
    assert safe.validated_format() == "bestaudio[ext=opus]"

    bad = server.DownloadOptions(url="https://youtu.be/abc", format="bestaudio; rm -rf /")
    with pytest.raises(HTTPException):
        bad.validated_format()

    none = server.DownloadOptions(url="https://youtu.be/abc", format="")
    assert none.validated_format() is None


# ── ydl_opts dict builder ───────────────────────────────────────────────

def _stub_job(server_mod):
    return server_mod.Job(id="test1234abcd", kind="download", target="music")


def test_build_ydl_opts_audio_only_defaults(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    opts = server.DownloadOptions(url="https://youtu.be/abc")
    cancel = threading.Event()
    ydl = server.build_ydl_opts(job, opts, "/tmp/x.%(ext)s", proxy=None, cancel=cancel)

    assert ydl["noplaylist"] is True
    assert ydl["format"] == "bestaudio/best"
    assert ydl["postprocessors"][0]["key"] == "FFmpegExtractAudio"
    assert ydl["postprocessors"][0]["preferredcodec"] == "opus"
    assert "proxy" not in ydl
    assert ydl["quiet"] is True
    assert ydl["noprogress"] is True
    assert callable(ydl["progress_hooks"][0])
    assert ydl["logger"].__class__.__name__ == "_JobLogger"


def test_build_ydl_opts_explicit_format_skips_audio_default(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    opts = server.DownloadOptions(
        url="https://youtu.be/abc", audio_only=False, format="best"
    )
    ydl = server.build_ydl_opts(job, opts, "/tmp/x.%(ext)s", proxy=None, cancel=threading.Event())
    assert ydl["format"] == "best"
    assert "postprocessors" not in ydl


def test_build_ydl_opts_proxy_and_bounded_options(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    opts = server.DownloadOptions(
        url="https://youtu.be/abc",
        no_playlist=False,
        playlist_start=2,
        playlist_end=5,
        max_filesize_mb=100,
        max_downloads=3,
    )
    ydl = server.build_ydl_opts(
        job, opts, "/tmp/x.%(ext)s", proxy="http://proxy:8888", cancel=threading.Event()
    )
    assert ydl["proxy"] == "http://proxy:8888"
    assert ydl["noplaylist"] is False
    assert ydl["playliststart"] == 2
    assert ydl["playlistend"] == 5
    assert ydl["max_filesize"] == 100 * 1024 * 1024
    assert ydl["max_downloads"] == 3


def test_progress_hook_raises_when_cancelled(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    cancel = threading.Event()
    hook = server._progress_hook(job, cancel)

    # Without cancel, hook is silent.
    hook({"status": "downloading", "_percent_str": " 12%", "_speed_str": "1MiB/s"})
    assert "downloading" in (job.detail or "")

    cancel.set()
    with pytest.raises(server._CancelledByDeadline):
        hook({"status": "downloading"})


def test_job_logger_ring_buffers(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    jlog = server._JobLogger(job, maxlines=3)
    for i in range(10):
        jlog.info(f"line {i}")
    assert job.detail.count("\n") == 2  # 3 lines, 2 newlines
    assert "line 9" in job.detail
    assert "line 0" not in job.detail


def test_job_logger_filters_debug_noise(app_client):
    server, _, _ = app_client
    job = _stub_job(server)
    jlog = server._JobLogger(job)
    jlog.debug("[debug] something internal")
    assert job.detail == ""
    jlog.debug("real-info-via-debug")
    assert "real-info-via-debug" in job.detail


def test_snapshot_audio_outputs_finds_recent(app_client):
    server, _, tmp_path = app_client
    dest = tmp_path / "music"
    dest.mkdir()
    old = dest / "old.opus"
    old.write_bytes(b"x")
    import time as _t
    _t.sleep(0.01)
    cutoff = _t.time()
    _t.sleep(0.01)
    new = dest / "new.opus"
    new.write_bytes(b"y")
    notes = dest / "notes.txt"
    notes.write_bytes(b"z")
    out = server._snapshot_audio_outputs(dest, since_mtime=cutoff)
    assert out == ["new.opus"]


# ── Upload ──────────────────────────────────────────────────────────────

def test_upload_writes_audio_file(app_client):
    server, client, tmp_path = app_client
    with client:
        f = io.BytesIO(b"OggSfake")
        r = client.post("/api/upload", data={"target": "music"}, files={"file": ("song.opus", f, "audio/opus")})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["job"]["status"] == "done"
        assert body["job"]["target"] == "music"
        assert len(body["job"]["files"]) == 1
        files = list((tmp_path / "music").iterdir())
        assert len(files) == 1
        assert files[0].name.endswith("song.opus")


def test_upload_unzips_archive(app_client):
    server, client, tmp_path = app_client
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("a.mp3", b"\x00\x01")
        zf.writestr("b.opus", b"\x02\x03")
        zf.writestr("../escape.txt", b"ignored-by-sanitizer")
    buf.seek(0)
    with client:
        r = client.post(
            "/api/upload",
            data={"target": "music"},
            files={"file": ("bundle.zip", buf, "application/zip")},
        )
        assert r.status_code == 200, r.text
        names = [p.name for p in (tmp_path / "music").iterdir()]
        assert any(n.endswith("a.mp3") for n in names)
        assert any(n.endswith("b.opus") for n in names)
        assert not (tmp_path / "escape.txt").exists()


def test_upload_rejects_unknown_target(app_client):
    server, client, _ = app_client
    with client:
        r = client.post(
            "/api/upload",
            data={"target": "media"},
            files={"file": ("song.opus", io.BytesIO(b"x"), "audio/opus")},
        )
        assert r.status_code == 400


# ── /api/download ───────────────────────────────────────────────────────

def test_is_retryable_ip_error(app_client):
    server, _, _ = app_client
    assert server._is_retryable_ip_error(Exception("[youtube] ABC: Sign in to confirm you're not a bot"))
    assert server._is_retryable_ip_error(Exception("HTTP Error 403: Forbidden"))
    assert server._is_retryable_ip_error(Exception("HTTP error 429 - too many requests"))
    assert not server._is_retryable_ip_error(Exception("Requested format not available"))
    assert not server._is_retryable_ip_error(Exception("HTTP Error 404: Not Found"))


def test_build_proxy_rotation_caps_at_pool(app_client, monkeypatch):
    server, _, _ = app_client
    monkeypatch.setattr(server, "YTDLP_MAX_EXIT_RETRIES", 3)
    monkeypatch.setattr(server, "EXITNODE_PROXIES", ["a", "b", "c", "d", "e"])
    rotation = server._build_proxy_rotation(use_exit_node=True)
    assert len(rotation) == 3
    assert all(p in {"a", "b", "c", "d", "e"} for p in rotation)
    assert len(set(rotation)) == 3  # no dupes


def test_build_proxy_rotation_empty_pool(app_client, monkeypatch):
    server, _, _ = app_client
    monkeypatch.setattr(server, "EXITNODE_PROXIES", [])
    rotation = server._build_proxy_rotation(use_exit_node=True)
    assert rotation == [None]


def test_build_proxy_rotation_use_exit_node_false_skips_pool(app_client, monkeypatch):
    """Direct mode bypasses the proxy pool even when one is configured."""
    server, _, _ = app_client
    monkeypatch.setattr(server, "EXITNODE_PROXIES", ["a", "b", "c"])
    rotation = server._build_proxy_rotation(use_exit_node=False)
    assert rotation == [None]


def test_download_options_use_exit_node_default_true(app_client):
    server, _, _ = app_client
    opts = server.DownloadOptions(url="https://youtu.be/abc")
    assert opts.use_exit_node is True
    opts2 = server.DownloadOptions(url="https://youtu.be/abc", use_exit_node=False)
    assert opts2.use_exit_node is False


@pytest.mark.asyncio
async def test_run_download_rotates_on_bot_check(app_client, tmp_path, monkeypatch):
    """First exit hits YouTube's bot wall; second exit succeeds."""
    server, _, _ = app_client
    monkeypatch.setattr(server, "EXITNODE_PROXIES", ["proxy-a", "proxy-b", "proxy-c"])
    monkeypatch.setattr(server, "YTDLP_MAX_EXIT_RETRIES", 3)

    attempts = []

    async def fake_attempt(job, opts, dest_dir, out_template, proxy):
        attempts.append(proxy)
        if len(attempts) == 1:
            # Simulate YouTube bot-check on first try.
            raise __import__("yt_dlp").utils.DownloadError(
                "ERROR: [youtube] ABC: Sign in to confirm you're not a bot"
            )
        # Second attempt succeeds — write a fake output file.
        (dest_dir / "track.opus").write_bytes(b"x")

    monkeypatch.setattr(server, "_attempt_download", fake_attempt)

    job = server.Job(id="j1", kind="download", target="music")
    opts = server.DownloadOptions(url="https://youtu.be/abc")
    await server.run_download(job, opts)

    assert len(attempts) == 2
    assert attempts[0] != attempts[1]  # rotated to a different exit
    assert "track.opus" in job.files


@pytest.mark.asyncio
async def test_run_download_no_retry_on_format_error(app_client, monkeypatch):
    """Format-mismatch errors are NOT IP-flagged; surface immediately."""
    server, _, _ = app_client
    monkeypatch.setattr(server, "EXITNODE_PROXIES", ["proxy-a", "proxy-b", "proxy-c"])
    monkeypatch.setattr(server, "YTDLP_MAX_EXIT_RETRIES", 3)

    attempts = []

    async def fake_attempt(job, opts, dest_dir, out_template, proxy):
        attempts.append(proxy)
        raise __import__("yt_dlp").utils.DownloadError(
            "ERROR: Requested format is not available"
        )

    monkeypatch.setattr(server, "_attempt_download", fake_attempt)

    job = server.Job(id="j1", kind="download", target="music")
    opts = server.DownloadOptions(url="https://youtu.be/abc")
    with pytest.raises(RuntimeError, match="format is not available"):
        await server.run_download(job, opts)
    assert len(attempts) == 1  # gave up after first failure


def test_download_endpoint_validates_payload(app_client):
    server, client, _ = app_client
    with client:
        r = client.post("/api/download", json={"url": "ftp://x"})
        assert r.status_code == 422  # Pydantic rejects non-http(s)

        r = client.post("/api/download", json={"url": "https://youtu.be/abc", "extra_field": "foo"})
        assert r.status_code == 422  # extra="forbid"

        r = client.post("/api/download", json={"url": "https://youtu.be/abc", "target": "media"})
        assert r.status_code == 422  # Literal["music"]


def test_download_endpoint_queues_job(app_client, monkeypatch):
    server, client, _ = app_client

    async def fake_run_download(job, opts):
        job.detail = "stub ok"
        job.files = ["fake.opus"]

    monkeypatch.setattr(server, "run_download", fake_run_download)

    with client:
        r = client.post(
            "/api/download",
            json={"url": "https://youtu.be/abc", "audio_only": True},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["job"]["kind"] == "download"
        assert body["job"]["target"] == "music"


def test_jobs_endpoint_returns_history(app_client):
    server, client, _ = app_client
    with client:
        client.post(
            "/api/upload",
            data={"target": "music"},
            files={"file": ("a.opus", io.BytesIO(b"x"), "audio/opus")},
        )
        r = client.get("/api/jobs")
        assert r.status_code == 200
        body = r.json()
        assert len(body["jobs"]) >= 1
        assert body["jobs"][0]["kind"] == "upload"


# ── /internal/* surface — bearer auth + pull endpoints ─────────────────

def _bearer_headers(token: str = "test-token-xyz") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_internal_requires_bearer(app_client):
    _, client, _ = app_client
    with client:
        r = client.get("/internal/dropzone/list")
        assert r.status_code == 401


def test_internal_rejects_wrong_bearer(app_client):
    _, client, _ = app_client
    with client:
        r = client.get("/internal/dropzone/list", headers=_bearer_headers("nope"))
        assert r.status_code == 401


def test_internal_503_when_token_unset(tmp_path, monkeypatch):
    os.environ["DROPZONE_PATH"] = str(tmp_path)
    os.environ["EXITNODE_PROXIES"] = ""
    os.environ["INGEST_INTERNAL_TOKEN"] = ""
    import importlib

    import server

    importlib.reload(server)
    with TestClient(server.app) as client:
        r = client.get("/internal/dropzone/list", headers=_bearer_headers())
        assert r.status_code == 503


def test_internal_list_empty(app_client):
    _, client, _ = app_client
    with client:
        r = client.get("/internal/dropzone/list", headers=_bearer_headers())
        assert r.status_code == 200
        assert r.json() == {"files": []}


def test_internal_list_returns_dropped_audio(app_client):
    server, client, tmp_path = app_client
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    (music / "track.opus").write_bytes(b"x")
    (music / "ignored.txt").write_text("nope")
    (music / "downloading.opus.part").write_bytes(b"y")
    with client:
        r = client.get("/internal/dropzone/list", headers=_bearer_headers())
        assert r.status_code == 200
        files = r.json()["files"]
        assert len(files) == 1
        assert files[0]["filename"] == "track.opus"
        assert "id" in files[0] and files[0]["size"] == 1


def test_internal_file_streams_bytes(app_client):
    server, client, tmp_path = app_client
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    (music / "track.opus").write_bytes(b"hello-bytes")
    with client:
        listing = client.get("/internal/dropzone/list", headers=_bearer_headers()).json()["files"]
        fid = listing[0]["id"]
        r = client.get(f"/internal/dropzone/file/{fid}", headers=_bearer_headers())
        assert r.status_code == 200
        assert r.content == b"hello-bytes"
        # X-Filename is URL-encoded for header safety.
        from urllib.parse import unquote
        assert unquote(r.headers["X-Filename"]) == "track.opus"


def test_internal_file_handles_unicode_filename(app_client):
    """Regression: full-width quotes (e.g. '＂') in filenames previously
    crashed the response with UnicodeEncodeError on Content-Disposition."""
    server, client, tmp_path = app_client
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    weird = music / "Evangelion ＂Cruel Angel＂.opus"
    weird.write_bytes(b"abc")
    with client:
        listing = client.get("/internal/dropzone/list", headers=_bearer_headers()).json()["files"]
        fid = listing[0]["id"]
        r = client.get(f"/internal/dropzone/file/{fid}", headers=_bearer_headers())
        assert r.status_code == 200
        assert r.content == b"abc"
        from urllib.parse import unquote
        assert "Evangelion" in unquote(r.headers["X-Filename"])


def test_internal_file_404_for_unknown_id(app_client):
    _, client, _ = app_client
    with client:
        r = client.get("/internal/dropzone/file/totally-bogus", headers=_bearer_headers())
        assert r.status_code == 404


def test_internal_ack_unlinks(app_client):
    server, client, tmp_path = app_client
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    p = music / "track.opus"
    p.write_bytes(b"x")
    with client:
        fid = client.get("/internal/dropzone/list", headers=_bearer_headers()).json()["files"][0]["id"]
        r = client.post(f"/internal/dropzone/ack/{fid}", headers=_bearer_headers())
        assert r.status_code == 200
        assert not p.exists()


def test_internal_quarantine_moves_to_failed(app_client):
    server, client, tmp_path = app_client
    music = tmp_path / "music"
    music.mkdir(parents=True, exist_ok=True)
    p = music / "track.opus"
    p.write_bytes(b"x")
    with client:
        fid = client.get("/internal/dropzone/list", headers=_bearer_headers()).json()["files"][0]["id"]
        r = client.post(
            f"/internal/dropzone/quarantine/{fid}",
            headers=_bearer_headers(),
            json={"reason": "low_confidence=0.2"},
        )
        assert r.status_code == 200
        assert not p.exists()
        failed = list((music / "failed").iterdir())
        assert any(f.name.endswith(".opus") for f in failed)
        assert any(f.name.endswith(".error.json") for f in failed)


def test_internal_path_visible_in_list_after_upload(app_client):
    """End-to-end: upload via /api/upload, then list via /internal/."""
    _, client, _ = app_client
    with client:
        client.post(
            "/api/upload",
            data={"target": "music"},
            files={"file": ("e2e.opus", io.BytesIO(b"abc"), "audio/opus")},
        )
        listing = client.get("/internal/dropzone/list", headers=_bearer_headers()).json()["files"]
        assert len(listing) == 1
        assert listing[0]["filename"].endswith("e2e.opus")
