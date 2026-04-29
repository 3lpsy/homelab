"""
Unit tests for server.py.

Runs the tool functions directly (bypassing FastMCP dispatch) with a
manually populated api-key ContextVar. Does not require the HTTP server
to be running. Run with `pytest test_server.py`.
"""
# Make the sibling `data/images/mcp-common/` package importable for tests
# without polluting `data/images/` with a top-level pyproject.toml + conftest.
import pathlib as _pathlib
import sys as _sys

_sys.path.insert(0, str(_pathlib.Path(__file__).resolve().parent.parent / "mcp-common"))

import asyncio
import os
import pathlib
import tempfile

_TMP = tempfile.mkdtemp(prefix="mcpfs-test-")
os.environ["MCP_PATH_SALT"] = "unit-test-salt"
os.environ["MCP_DATA_ROOT"] = _TMP
os.environ["MCP_API_KEYS"] = "key-a,key-b,key-c"
os.environ.setdefault("LOG_LEVEL", "error")

import pytest  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


@pytest.fixture
def key_a():
    tok = server.current_api_key.set("key-a")
    try:
        yield "key-a"
    finally:
        server.current_api_key.reset(tok)


@pytest.fixture
def key_b():
    tok = server.current_api_key.set("key-b")
    try:
        yield "key-b"
    finally:
        server.current_api_key.reset(tok)


# --- _hash / _session_root ---------------------------------------------------


def test_hash_deterministic():
    assert server._hash("x") == server._hash("x")
    assert server._hash("x") != server._hash("y")


def test_session_root_unique_per_key_and_session(key_a):
    r1 = server._session_root("s1")
    r2 = server._session_root("s2")
    assert r1 != r2
    assert r1.exists() and r2.exists()

    server.current_api_key.set("key-b")
    r3 = server._session_root("s1")
    assert r3 != r1  # different tenant


def test_session_root_requires_api_key():
    # Fresh context with no key set
    ctx_var_value = server.current_api_key.get()
    assert ctx_var_value == "" or ctx_var_value is None  # default
    with pytest.raises(PermissionError):
        server._session_root("s1")


def test_session_root_rejects_empty_session(key_a):
    with pytest.raises(ValueError):
        server._session_root("")
    with pytest.raises(ValueError):
        server._session_root("   ")


# --- _safe sandboxing --------------------------------------------------------


def test_safe_accepts_relative(key_a):
    p = server._safe("s1", "foo.txt")
    root = server._session_root("s1")
    assert p.parent == root
    assert p.name == "foo.txt"


def test_safe_treats_absolute_as_relative(key_a):
    a = server._safe("s1", "/foo.txt")
    b = server._safe("s1", "foo.txt")
    assert a == b


def test_safe_rejects_parent_escape(key_a):
    with pytest.raises(PermissionError):
        server._safe("s1", "../../../../etc/passwd")


def test_safe_no_side_effects_on_escape(key_a):
    """Escape attempts must not mkdir intermediate components."""
    root = server._session_root("s1")
    before = set(p.name for p in root.parent.parent.iterdir())
    with pytest.raises(PermissionError):
        server._safe("s1", "a/b/c/../../../../../evil")
    after = set(p.name for p in root.parent.parent.iterdir())
    assert before == after


def test_safe_rejects_symlink_escape(key_a, tmp_path):
    outside = tmp_path / "outside.txt"
    outside.write_text("secret")
    root = server._session_root("s1")
    link = root / "escape"
    link.symlink_to(outside)
    with pytest.raises(PermissionError):
        server._safe("s1", "escape", must_exist=True)


def test_safe_must_exist(key_a):
    with pytest.raises(FileNotFoundError):
        server._safe("s1", "does-not-exist.txt", must_exist=True)


# --- read_file / write_file round trip --------------------------------------


def test_write_then_read(key_a):
    _call(server.write_file("s1", "hello.txt", "world"))
    out = _call(server.read_file("s1", "hello.txt"))
    assert out == "world"


def test_write_creates_parents(key_a):
    _call(server.write_file("s1", "a/b/c/d.txt", "hi"))
    out = _call(server.read_file("s1", "a/b/c/d.txt"))
    assert out == "hi"


def test_write_file_parent_mkdir_comes_from_safe(key_a):
    # write_file no longer mkdirs p.parent itself — _safe must do it. Writing
    # into a nested path where none of the intermediate dirs exist must still
    # succeed and produce real directories end-to-end.
    _call(server.write_file("mkdir-check", "deep/er/still/file.txt", "hi"))
    root = server._session_root("mkdir-check")
    assert (root / "deep").is_dir()
    assert (root / "deep" / "er").is_dir()
    assert (root / "deep" / "er" / "still").is_dir()
    assert (root / "deep" / "er" / "still" / "file.txt").read_text() == "hi"


# --- tenant + session isolation ---------------------------------------------


def test_tenant_isolation():
    server.current_api_key.set("key-a")
    _call(server.write_file("s1", "secret.txt", "A's data"))

    server.current_api_key.set("key-b")
    entries = _call(server.list_directory("s1"))
    assert entries == []  # B sees empty — different tenant dir

    with pytest.raises(FileNotFoundError):
        _call(server.read_file("s1", "secret.txt"))


def test_session_isolation(key_a):
    _call(server.write_file("alpha", "x.txt", "one"))
    entries_beta = _call(server.list_directory("beta"))
    assert entries_beta == []
    with pytest.raises(FileNotFoundError):
        _call(server.read_file("beta", "x.txt"))


# --- edit_file --------------------------------------------------------------


def test_edit_file_exact_match(key_a):
    _call(server.write_file("s1", "e.txt", "alpha\nbeta\ngamma\n"))
    diff = _call(server.edit_file("s1", "e.txt", [{"oldText": "beta", "newText": "BETA"}]))
    assert "beta" in diff and "BETA" in diff
    content = _call(server.read_file("s1", "e.txt"))
    assert content == "alpha\nBETA\ngamma\n"


def test_edit_file_whitespace_flexible_match(key_a):
    # Trimmed-line match succeeds even though old text has no leading indent
    # while source is indented. First-line indent comes from the source;
    # subsequent lines get `first_indent + max(0, new_indent - old_indent)`.
    src = "    if x:\n        print(x)\n"
    _call(server.write_file("edit-flex", "f.py", src))
    _call(server.edit_file(
        "edit-flex",
        "f.py",
        [{"oldText": "if x:\n    print(x)", "newText": "if x:\n    print('hi')"}],
    ))
    out = _call(server.read_file("edit-flex", "f.py"))
    # old has 4-space indent on line 2, new has 4-space indent on line 2.
    # Delta is 0, so subsequent line gets original_indent (4) + 0 + trimmed.
    assert out == "    if x:\n    print('hi')\n"


def test_edit_file_preserves_relative_nested_indent(key_a):
    src = "def f():\n    return 1\n"
    _call(server.write_file("edit-nested", "g.py", src))
    # new adds a deeper block; the +4 delta in new relative to old is applied.
    _call(server.edit_file(
        "edit-nested",
        "g.py",
        [{
            "oldText": "def f():\n    return 1",
            "newText": "def f():\n    if True:\n        return 1",
        }],
    ))
    out = _call(server.read_file("edit-nested", "g.py"))
    assert out == "def f():\n    if True:\n        return 1\n"


def test_edit_file_no_match_raises(key_a):
    _call(server.write_file("s1", "g.txt", "abc\n"))
    with pytest.raises(ValueError):
        _call(server.edit_file("s1", "g.txt", [{"oldText": "does-not-exist", "newText": "x"}]))
    # file untouched
    assert _call(server.read_file("s1", "g.txt")) == "abc\n"


def test_edit_file_dry_run_does_not_mutate(key_a):
    _call(server.write_file("s1", "h.txt", "orig\n"))
    _call(server.edit_file(
        "s1", "h.txt", [{"oldText": "orig", "newText": "new"}], dry_run=True,
    ))
    assert _call(server.read_file("s1", "h.txt")) == "orig\n"


def test_edit_file_preserves_crlf(key_a):
    # Write CRLF content directly (write_file writes raw; no normalization).
    _call(server.write_file("crlf", "win.txt", "one\r\ntwo\r\nthree\r\n"))
    _call(server.edit_file(
        "crlf", "win.txt", [{"oldText": "two", "newText": "TWO"}],
    ))
    # Bytes round-trip: CRLF endings must survive the edit.
    root = server._session_root("crlf")
    assert (root / "win.txt").read_bytes() == b"one\r\nTWO\r\nthree\r\n"


# --- list_directory / directory_tree / search_files / move_file -------------


def test_list_directory(key_a):
    _call(server.write_file("s1", "a.txt", "a"))
    _call(server.create_directory("s1", "subdir"))
    entries = _call(server.list_directory("s1"))
    names = {e["name"]: e["type"] for e in entries}
    assert names.get("a.txt") == "file"
    assert names.get("subdir") == "dir"


def test_directory_tree(key_a):
    _call(server.write_file("s1", "x/y/z.txt", "z"))
    tree = _call(server.directory_tree("s1"))
    x = next((n for n in tree if n["name"] == "x"), None)
    assert x and x["type"] == "dir"
    y = next((n for n in x["children"] if n["name"] == "y"), None)
    assert y and y["type"] == "dir"
    z = next((n for n in y["children"] if n["name"] == "z.txt"), None)
    assert z and z["type"] == "file"


def test_search_files(key_a):
    _call(server.write_file("search-basic", "one.py", "a"))
    _call(server.write_file("search-basic", "two.py", "b"))
    _call(server.write_file("search-basic", "three.txt", "c"))
    hits = _call(server.search_files("search-basic", "*.py"))
    assert {pathlib.Path(h).name for h in hits} == {"one.py", "two.py"}


def test_search_files_excludes(key_a):
    _call(server.write_file("search-excl", "a.log", "a"))
    _call(server.write_file("search-excl", "b.log", "b"))
    _call(server.write_file("search-excl", "skip/ignored.log", "c"))
    hits = _call(server.search_files("search-excl", "*.log", exclude_patterns=["skip"]))
    names = {pathlib.Path(h).name for h in hits}
    assert names == {"a.log", "b.log"}


def test_move_file(key_a):
    _call(server.write_file("s1", "src.txt", "x"))
    _call(server.move_file("s1", "src.txt", "dst.txt"))
    with pytest.raises(FileNotFoundError):
        _call(server.read_file("s1", "src.txt"))
    assert _call(server.read_file("s1", "dst.txt")) == "x"


def test_get_file_info(key_a):
    _call(server.write_file("s1", "i.txt", "hello"))
    info = _call(server.get_file_info("s1", "i.txt"))
    assert info["size"] == 5
    assert info["type"] == "file"
    assert "is_dir" not in info  # replaced by `type` to match listing vocab


def test_list_allowed_directories(key_a):
    assert _call(server.list_allowed_directories("s1")) == ["/"]


def test_destroy_session_removes_all_files(key_a):
    _call(server.write_file("doomed", "a.txt", "1"))
    _call(server.write_file("doomed", "nested/b.txt", "2"))
    result = _call(server.destroy_session("doomed"))
    assert result == {"session_id": "doomed", "removed": True}
    # Files gone — next read fails.
    with pytest.raises(FileNotFoundError):
        _call(server.read_file("doomed", "a.txt"))
    # Listing the session re-creates the dir but it's empty.
    assert _call(server.list_directory("doomed")) == []


def test_destroy_session_noop_when_empty(key_a):
    # Never-written session: tool reports removed=False without error.
    result = _call(server.destroy_session("never-used"))
    assert result == {"session_id": "never-used", "removed": False}


def test_destroy_session_does_not_touch_other_sessions(key_a):
    _call(server.write_file("keep", "k.txt", "survives"))
    _call(server.write_file("toast", "t.txt", "dies"))
    _call(server.destroy_session("toast"))
    assert _call(server.read_file("keep", "k.txt")) == "survives"


def test_list_sessions_empty_for_fresh_tenant():
    # key-c is never used by any other test, so its index is empty.
    server.current_api_key.set("key-c")
    assert _call(server.list_sessions()) == []


def test_sessions_index_auto_populates_on_new_session(key_a):
    _call(server.write_file("idx-one", "a.txt", "x"))
    _call(server.write_file("idx-two", "b.txt", "y"))
    sessions = _call(server.list_sessions())
    ids = {s["session_id"] for s in sessions}
    assert {"idx-one", "idx-two"} <= ids
    for s in sessions:
        if s["session_id"] in {"idx-one", "idx-two"}:
            assert s["description"] == ""


def test_describe_session_updates_entry(key_a):
    _call(server.write_file("desc-target", "a.txt", "x"))
    _call(server.describe_session("desc-target", "scratch work for bug #42"))
    sessions = _call(server.list_sessions())
    hit = next(s for s in sessions if s["session_id"] == "desc-target")
    assert hit["description"] == "scratch work for bug #42"


def test_describe_session_rejects_overlong(key_a):
    too_long = "x" * (server.MCP_MAX_DESCRIPTION_CHARS + 1)
    with pytest.raises(ValueError):
        _call(server.describe_session("too-wordy", too_long))


def test_describe_session_accepts_boundary(key_a):
    at_limit = "x" * server.MCP_MAX_DESCRIPTION_CHARS
    _call(server.describe_session("at-limit", at_limit))
    hit = next(s for s in _call(server.list_sessions()) if s["session_id"] == "at-limit")
    assert hit["description"] == at_limit


def test_describe_session_creates_missing_entry(key_a):
    # Session that has never been written to.
    _call(server.describe_session("brand-new", "hello"))
    sessions = _call(server.list_sessions())
    hit = next(s for s in sessions if s["session_id"] == "brand-new")
    assert hit["description"] == "hello"


def test_destroy_session_removes_from_index(key_a):
    _call(server.write_file("index-drop", "x.txt", "x"))
    _call(server.destroy_session("index-drop"))
    ids = {s["session_id"] for s in _call(server.list_sessions())}
    assert "index-drop" not in ids


def test_sessions_are_tenant_scoped():
    server.current_api_key.set("key-a")
    _call(server.describe_session("only-a", "A's session"))
    server.current_api_key.set("key-b")
    ids = {s["session_id"] for s in _call(server.list_sessions())}
    assert "only-a" not in ids


def test_destroy_session_does_not_touch_other_tenants():
    server.current_api_key.set("key-a")
    _call(server.write_file("shared-id", "mine.txt", "A"))
    server.current_api_key.set("key-b")
    _call(server.write_file("shared-id", "mine.txt", "B"))
    # B destroys their session — A's data must survive.
    _call(server.destroy_session("shared-id"))
    server.current_api_key.set("key-a")
    assert _call(server.read_file("shared-id", "mine.txt")) == "A"


# --- size / batch caps ------------------------------------------------------


def test_read_file_size_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_FILE_BYTES", 10)
    _call(server.write_file("cap-read", "big.txt", "x" * 5))  # under cap, write ok
    # now put a bigger file on disk, bypassing the write cap
    root = server._session_root("cap-read")
    (root / "too-big.txt").write_text("x" * 50)
    with pytest.raises(ValueError):
        _call(server.read_file("cap-read", "too-big.txt"))


def test_write_file_size_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_FILE_BYTES", 10)
    with pytest.raises(ValueError):
        _call(server.write_file("cap-write", "big.txt", "x" * 50))
    # no file created, no tmp left behind
    root_dir = server.DATA_ROOT / server._hash("key-a") / server._hash("cap-write")
    # session root may have been created by _session_root_path chain; just
    # assert no file made it in.
    assert not (root_dir / "big.txt").exists()
    leftovers = list(root_dir.glob("big.txt.*.tmp")) if root_dir.exists() else []
    assert leftovers == []


def test_edit_file_edit_count_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_EDITS", 2)
    _call(server.write_file("cap-edits", "f.txt", "a\nb\nc\n"))
    edits = [
        {"oldText": "a", "newText": "A"},
        {"oldText": "b", "newText": "B"},
        {"oldText": "c", "newText": "C"},
    ]
    with pytest.raises(ValueError):
        _call(server.edit_file("cap-edits", "f.txt", edits))
    assert _call(server.read_file("cap-edits", "f.txt")) == "a\nb\nc\n"


def test_edit_file_dry_run_still_enforces_output_cap(key_a, monkeypatch):
    # The post-edit size check must fire even when dry_run=True, otherwise
    # a caller can force unbounded memory use under the guise of "just a preview".
    monkeypatch.setattr(server, "MCP_MAX_FILE_BYTES", 20)
    _call(server.write_file("cap-dry", "f.txt", "hello"))
    big = "x" * 200
    with pytest.raises(ValueError):
        _call(server.edit_file(
            "cap-dry", "f.txt",
            [{"oldText": "hello", "newText": big}],
            dry_run=True,
        ))


def test_edit_file_per_edit_byte_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_EDIT_BYTES", 8)
    _call(server.write_file("cap-peredit", "f.txt", "abc"))
    with pytest.raises(ValueError):
        _call(server.edit_file(
            "cap-peredit", "f.txt",
            [{"oldText": "abc", "newText": "x" * 50}],
        ))
    with pytest.raises(ValueError):
        _call(server.edit_file(
            "cap-peredit", "f.txt",
            [{"oldText": "y" * 50, "newText": "z"}],
        ))


def test_edit_file_pre_read_size_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_FILE_BYTES", 10)
    _call(server.write_file("cap-edit-size", "f.txt", "ok"))
    root = server._session_root("cap-edit-size")
    (root / "f.txt").write_text("x" * 50)  # grow past cap out-of-band
    with pytest.raises(ValueError):
        _call(server.edit_file("cap-edit-size", "f.txt", [{"oldText": "x", "newText": "y"}]))


def test_read_multiple_files_batch_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_READ_BATCH", 2)
    _call(server.write_file("cap-batch", "a.txt", "a"))
    _call(server.write_file("cap-batch", "b.txt", "b"))
    _call(server.write_file("cap-batch", "c.txt", "c"))
    with pytest.raises(ValueError):
        _call(server.read_multiple_files("cap-batch", ["a.txt", "b.txt", "c.txt"]))


def test_read_multiple_files_per_entry_size_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_FILE_BYTES", 5)
    _call(server.write_file("cap-batch-sz", "small.txt", "hi"))
    root = server._session_root("cap-batch-sz")
    (root / "big.txt").write_text("x" * 50)
    res = _call(server.read_multiple_files("cap-batch-sz", ["small.txt", "big.txt"]))
    assert res["small.txt"]["ok"] is True
    assert res["big.txt"]["ok"] is False
    assert "MCP_MAX_FILE_BYTES" in res["big.txt"]["error"]


# --- symlink refusal / move overwrite ---------------------------------------


def test_get_file_info_refuses_symlink(key_a, tmp_path):
    _call(server.write_file("sym-info", "real.txt", "x"))
    root = server._session_root("sym-info")
    outside = tmp_path / "t.txt"
    outside.write_text("secret")
    (root / "link").symlink_to(outside)
    with pytest.raises(PermissionError):
        _call(server.get_file_info("sym-info", "link"))


def test_move_file_refuses_symlink_src(key_a, tmp_path):
    _call(server.write_file("sym-move", "real.txt", "x"))
    root = server._session_root("sym-move")
    outside = tmp_path / "t.txt"
    outside.write_text("secret")
    (root / "link").symlink_to(outside)
    with pytest.raises(PermissionError):
        _call(server.move_file("sym-move", "link", "dst"))


def test_move_file_no_overwrite_by_default(key_a):
    _call(server.write_file("mv-no-clobber", "a.txt", "A"))
    _call(server.write_file("mv-no-clobber", "b.txt", "B"))
    with pytest.raises(FileExistsError):
        _call(server.move_file("mv-no-clobber", "a.txt", "b.txt"))
    # both files untouched
    assert _call(server.read_file("mv-no-clobber", "a.txt")) == "A"
    assert _call(server.read_file("mv-no-clobber", "b.txt")) == "B"


def test_search_files_skips_symlinks(key_a, tmp_path):
    outside = tmp_path / "out"
    outside.mkdir()
    (outside / "target.log").write_text("secret")

    _call(server.write_file("sym-search", "real.log", "a"))
    root = server._session_root("sym-search")
    (root / "linked.log").symlink_to(outside / "target.log")
    (root / "linked-dir").symlink_to(outside)

    hits = _call(server.search_files("sym-search", "*.log"))
    names = {pathlib.Path(h).name for h in hits}
    assert names == {"real.log"}  # symlinks filtered out


def test_list_allowed_directories_does_not_create_session_root(key_a):
    # Previously _session_root(mkdir=True default) would materialize the dir
    # just to validate. With mkdir=False, the call stays pure.
    root = server.DATA_ROOT / server._hash("key-a") / server._hash("pure-validate")
    assert not root.exists()
    assert _call(server.list_allowed_directories("pure-validate")) == ["/"]
    assert not root.exists()


def test_move_file_overwrite_true(key_a):
    _call(server.write_file("mv-clobber", "a.txt", "A"))
    _call(server.write_file("mv-clobber", "b.txt", "B"))
    _call(server.move_file("mv-clobber", "a.txt", "b.txt", overwrite=True))
    assert _call(server.read_file("mv-clobber", "b.txt")) == "A"
    with pytest.raises(FileNotFoundError):
        _call(server.read_file("mv-clobber", "a.txt"))


# --- log format -------------------------------------------------------------


def test_auth_log_escapes_control_chars_in_path(caplog):
    import logging as _logging

    from mcp_common.auth import AuthMiddleware

    # Hit the rejection branch directly with a scope that has CRLF in the path.
    # We don't need the live server — just call the middleware.
    rejected: dict = {"sent": []}

    async def _send(msg):
        rejected["sent"].append(msg)

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    mw = AuthMiddleware(
        lambda *a, **kw: None,
        api_keys=server.API_KEYS,
        logger=server.log,
    )
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/evil\r\nINJECTED",
        "query_string": b"",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    }
    caplog.set_level(_logging.WARNING, logger="mcp-filesystem")
    asyncio.run(mw(scope, _recv, _send))
    # caplog.text is the rendered format; raw CRLF must not appear in it
    assert "INJECTED" in caplog.text
    assert "\r\n" not in caplog.text
    assert "\\r\\n" in caplog.text or "\\n" in caplog.text


def test_list_and_tree_surface_symlinks_as_type(key_a, tmp_path):
    # Symlinks inside the session root must be visible (so the LLM knows
    # they exist) but typed distinctly so downstream tools refuse them.
    outside = tmp_path / "outside-target"
    outside.mkdir()
    (outside / "leak.txt").write_text("secret")

    _call(server.write_file("symcheck", "real.txt", "hi"))
    root = server._session_root("symcheck")
    (root / "escape").symlink_to(outside)

    entries = _call(server.list_directory("symcheck"))
    typed = {e["name"]: e["type"] for e in entries}
    assert typed == {"real.txt": "file", "escape": "symlink"}

    tree = _call(server.directory_tree("symcheck"))
    tree_typed = {n["name"]: n["type"] for n in tree}
    assert tree_typed == {"real.txt": "file", "escape": "symlink"}
    # symlink node has no `children` key (not followed)
    escape_node = next(n for n in tree if n["name"] == "escape")
    assert "children" not in escape_node


def test_display_has_no_filesystem_side_effects(key_a):
    # _display used to invoke _session_root, which mkdirs. It must now be pure.
    fake_path = server._session_root_path("display-pure-check") / "nope.txt"
    root = server.DATA_ROOT / server._hash("key-a") / server._hash("display-pure-check")
    assert not root.exists()
    out = server._display(fake_path, "display-pure-check")
    assert out == "/nope.txt"
    assert not root.exists()  # _display did not create the session root


# --- session_id validation --------------------------------------------------


def test_session_id_rejects_spaces(key_a):
    with pytest.raises(ValueError):
        server._session_root_path("has space")


def test_session_id_rejects_control_chars(key_a):
    with pytest.raises(ValueError):
        server._session_root_path("nl\nin-id")


def test_session_id_rejects_path_separators(key_a):
    # `/` and `\` would already be defanged by hashing, but the regex
    # rejects them up front so the LLM gets a clean error early.
    with pytest.raises(ValueError):
        server._session_root_path("a/b")
    with pytest.raises(ValueError):
        server._session_root_path("a\\b")


def test_session_id_rejects_overlong(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_SESSION_ID_CHARS", 8)
    with pytest.raises(ValueError):
        server._session_root_path("x" * 9)
    # Boundary still ok.
    server._session_root_path("x" * 8)


def test_session_id_accepts_allowed_charset(key_a):
    # All chars in [A-Za-z0-9._-] must work.
    for sid in ("abc", "ABC", "0123", "a.b", "a-b", "a_b", "Mix.1-2_3"):
        server._session_root_path(sid)


def test_session_id_validation_runs_in_tools(key_a):
    # End-to-end: a tool call with an invalid session_id must raise before
    # any filesystem touch.
    with pytest.raises(ValueError):
        _call(server.write_file("bad id", "x.txt", "y"))


# --- session-count quota ----------------------------------------------------
#
# These tests bind a unique api-key string into the contextvar instead of
# using the shared key-a/b/c fixtures. The tenant dir is hashed from the
# bound key, so a unique string = clean isolated tenant with no prior
# sessions or files from other tests in the same module.


def test_session_count_cap_blocks_new_session(monkeypatch):
    server.current_api_key.set("isolated-scount-block")
    monkeypatch.setattr(server, "MCP_MAX_SESSIONS_PER_TENANT", 2)
    _call(server.write_file("scount-1", "a.txt", "x"))
    _call(server.write_file("scount-2", "a.txt", "x"))
    with pytest.raises(ValueError) as exc:
        _call(server.write_file("scount-3", "a.txt", "x"))
    assert "MCP_MAX_SESSIONS_PER_TENANT" in str(exc.value)


def test_session_count_cap_allows_reuse_of_existing(monkeypatch):
    server.current_api_key.set("isolated-scount-reuse")
    monkeypatch.setattr(server, "MCP_MAX_SESSIONS_PER_TENANT", 2)
    # Pre-fill the index up to the cap, then re-open one of them.
    _call(server.describe_session("reuse-1", "first"))
    _call(server.describe_session("reuse-2", "second"))
    # Re-opening "reuse-1" must NOT trip the cap even though we're at it.
    _call(server.write_file("reuse-1", "again.txt", "y"))
    assert _call(server.read_file("reuse-1", "again.txt")) == "y"


# --- tenant disk quota ------------------------------------------------------
#
# Same isolation pattern — fresh contextvar string per test so prior tests'
# writes under shared keys don't pre-fill the tenant past the cap.


def test_tenant_quota_blocks_oversize_write(monkeypatch):
    server.current_api_key.set("isolated-quota-oversize")
    monkeypatch.setattr(server, "MCP_MAX_TENANT_BYTES", 20)
    _call(server.write_file("quota-tiny", "a.txt", "x" * 10))  # under cap
    with pytest.raises(ValueError) as exc:
        _call(server.write_file("quota-tiny", "b.txt", "y" * 50))
    assert "MCP_MAX_TENANT_BYTES" in str(exc.value)


def test_tenant_quota_offsets_replaced_file(monkeypatch):
    # Replacing an existing file should subtract its current size from the
    # projection, otherwise overwrites at the cap would always fail.
    server.current_api_key.set("isolated-quota-replace")
    monkeypatch.setattr(server, "MCP_MAX_TENANT_BYTES", 20)
    _call(server.write_file("quota-replace", "a.txt", "x" * 15))
    # Same byte-count overwrite — net zero, must be allowed.
    _call(server.write_file("quota-replace", "a.txt", "y" * 15))
    assert _call(server.read_file("quota-replace", "a.txt")) == "y" * 15


def test_tenant_quota_blocks_edit(monkeypatch):
    server.current_api_key.set("isolated-quota-edit")
    _call(server.write_file("quota-edit", "f.txt", "abc"))
    monkeypatch.setattr(server, "MCP_MAX_TENANT_BYTES", 5)
    with pytest.raises(ValueError) as exc:
        _call(server.edit_file(
            "quota-edit", "f.txt",
            [{"oldText": "abc", "newText": "x" * 100}],
        ))
    assert "MCP_MAX_TENANT_BYTES" in str(exc.value)


def test_tenant_quota_dry_run_edit_skips_check(monkeypatch):
    # dry_run never writes to disk so it must not consult the quota; the
    # per-file MCP_MAX_FILE_BYTES check still fires elsewhere.
    server.current_api_key.set("isolated-quota-dryrun")
    _call(server.write_file("quota-edit-dry", "f.txt", "abc"))
    monkeypatch.setattr(server, "MCP_MAX_TENANT_BYTES", 5)
    out = _call(server.edit_file(
        "quota-edit-dry", "f.txt",
        [{"oldText": "abc", "newText": "abcd"}],
        dry_run=True,
    ))
    assert "diff" in out


def test_tenant_quota_is_per_tenant(monkeypatch):
    # Tenant-A hits the cap; tenant-B with the same logical session_id is
    # unaffected because hashes diverge by api-key.
    monkeypatch.setattr(server, "MCP_MAX_TENANT_BYTES", 30)
    server.current_api_key.set("isolated-quota-split-A")
    _call(server.write_file("split-quota", "a.txt", "x" * 25))
    with pytest.raises(ValueError):
        _call(server.write_file("split-quota", "b.txt", "y" * 25))

    server.current_api_key.set("isolated-quota-split-B")
    # B's tenant dir is separate, so a fresh write must succeed.
    _call(server.write_file("split-quota", "a.txt", "x" * 25))


# --- list_directory cap -----------------------------------------------------


def test_list_directory_truncates_with_sentinel(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_DIR_ENTRIES", 3)
    for i in range(5):
        _call(server.write_file("ld-cap", f"f{i:02d}.txt", "x"))
    entries = _call(server.list_directory("ld-cap"))
    # 3 files + 1 truncation sentinel
    assert len(entries) == 4
    assert entries[-1] == {"name": "...", "type": "truncated"}
    # The first 3 entries are sorted lexicographically (deterministic for
    # the under-cap collected portion).
    real = [e for e in entries if e["type"] != "truncated"]
    names = [e["name"] for e in real]
    assert names == sorted(names)


def test_list_directory_no_sentinel_when_under_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_DIR_ENTRIES", 100)
    _call(server.write_file("ld-clean", "a.txt", "x"))
    entries = _call(server.list_directory("ld-clean"))
    assert all(e["type"] != "truncated" for e in entries)


# --- directory_tree caps ----------------------------------------------------


def test_directory_tree_depth_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_TREE_DEPTH", 1)
    _call(server.write_file("dt-depth", "a/b/c/d.txt", "deep"))
    tree = _call(server.directory_tree("dt-depth"))
    # depth 0 → "a" (dir), depth 1 → "b" (dir but at cap, children=truncated)
    a = next(n for n in tree if n["name"] == "a")
    assert a["type"] == "dir"
    b = next(n for n in a["children"] if n["name"] == "b")
    assert b["type"] == "dir"
    assert b["children"] == [{"name": "...", "type": "truncated"}]


def test_directory_tree_node_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_TREE_NODES", 2)
    for n in ("a", "b", "c", "d"):
        _call(server.write_file("dt-nodes", f"{n}.txt", "x"))
    tree = _call(server.directory_tree("dt-nodes"))
    # Stops emitting real entries after the first 2 nodes; trailing sentinel
    # must appear so the LLM sees the listing was incomplete.
    real = [n for n in tree if n["type"] != "truncated"]
    sent = [n for n in tree if n["type"] == "truncated"]
    assert len(real) <= 2
    assert sent and sent[0] == {"name": "...", "type": "truncated"}


def test_directory_tree_per_dir_entry_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_DIR_ENTRIES", 2)
    monkeypatch.setattr(server, "MCP_MAX_TREE_NODES", 100)
    for n in ("a", "b", "c", "d"):
        _call(server.write_file("dt-perdir", f"{n}.txt", "x"))
    tree = _call(server.directory_tree("dt-perdir"))
    # Per-dir cap of 2 + sentinel = 3 entries at the root.
    assert len(tree) == 3
    assert tree[-1] == {"name": "...", "type": "truncated"}


# --- search_files cap -------------------------------------------------------


def test_search_files_hits_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_SEARCH_HITS", 3)
    for i in range(10):
        _call(server.write_file("sf-cap", f"x{i:02d}.log", "x"))
    hits = _call(server.search_files("sf-cap", "*.log"))
    # 3 real hits + 1 truncation marker string
    real = [h for h in hits if not h.startswith("... (truncated")]
    sent = [h for h in hits if h.startswith("... (truncated")]
    assert len(real) == 3
    assert len(sent) == 1


def test_search_files_no_sentinel_when_under_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_SEARCH_HITS", 100)
    _call(server.write_file("sf-clean", "a.log", "x"))
    hits = _call(server.search_files("sf-clean", "*.log"))
    assert not any(h.startswith("... (truncated") for h in hits)


# --- defaults / instructions wiring ----------------------------------------


def test_max_edit_bytes_default_is_256kib():
    # Lowered from 10 MiB to keep `MCP_MAX_EDITS * MCP_MAX_EDIT_BYTES` peak
    # memory inside the 512 Mi pod limit.
    assert server.MCP_MAX_EDIT_BYTES == 256 * 1024


def test_instructions_present_on_server():
    # FastMCP stores constructor `instructions=` for clients to fetch.
    inst = getattr(server.mcp, "instructions", None) or ""
    assert "session_id" in inst.lower()
    assert "destructive" in inst.lower() or "destroy_session" in inst


# --- HTTP integration tests -------------------------------------------------
# Spin the actual uvicorn + Starlette + FastMCP stack in a background thread
# and drive it with a real HTTP client. These exercise the AuthMiddleware
# path and confirm the api-key contextvar survives into tool handlers — the
# bug that raw BaseHTTPMiddleware would silently break.

import socket  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

import httpx  # noqa: E402
import uvicorn as _uvicorn  # noqa: E402
from fastmcp import Client  # noqa: E402
from fastmcp.client.transports import StreamableHttpTransport  # noqa: E402


def _free_port() -> int:
    # Bind to :0, let the OS pick a free port, return it.
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def live_server():
    # Start uvicorn in a daemon thread serving the real ASGI app.
    port = _free_port()
    config = _uvicorn.Config(
        server.app, host="127.0.0.1", port=port, log_level="error", lifespan="on",
        ws="none",
    )
    srv = _uvicorn.Server(config)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()

    # Poll until uvicorn flips started=True (or give up after 5s).
    deadline = time.time() + 5.0
    while time.time() < deadline and not srv.started:
        time.sleep(0.05)
    assert srv.started, "uvicorn did not start in time"

    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        # Signal shutdown and join the thread so the next test module gets a clean slate.
        srv.should_exit = True
        thread.join(timeout=5)


def test_http_rejects_missing_bearer(live_server):
    # No Authorization header → AuthMiddleware returns 401 before routing.
    r = httpx.post(f"{live_server}/", json={}, timeout=5)
    assert r.status_code == 401


def test_http_rejects_bad_bearer(live_server):
    # Unknown token → 401.
    r = httpx.post(
        f"{live_server}/",
        json={},
        headers={"Authorization": "Bearer not-a-real-key"},
        timeout=5,
    )
    assert r.status_code == 401


def test_http_accepts_query_param_key(live_server):
    # ?api_key=... fallback path must also authenticate. A raw POST without a
    # valid MCP payload will not be 401 — it will be some 4xx/5xx from the
    # protocol layer. We only assert auth passed (i.e. not 401).
    r = httpx.post(f"{live_server}/?api_key=key-a", json={}, timeout=5)
    assert r.status_code != 401


def test_http_healthz_no_auth(live_server):
    # Kubelet probe — no bearer, must succeed.
    r = httpx.get(f"{live_server}/healthz", timeout=5)
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_mcp_end_to_end_tool_call(live_server):
    # Full MCP handshake + tool call over real HTTP. This is the load-bearing
    # test for the middleware fix: if the api-key contextvar does not reach
    # the tool handler, _session_root() raises PermissionError and the call
    # comes back as an error.
    # The server is mounted at "/" (matches production: nginx proxy_pass at /),
    # so the MCP client must connect to "/", not "/mcp/".
    url = f"{live_server}/"
    transport = StreamableHttpTransport(url, headers={"Authorization": "Bearer key-a"})

    async def scenario():
        async with Client(transport) as client:
            # Write via HTTP → read via HTTP, round-trip through the real stack.
            await client.call_tool(
                "write_file",
                {"session_id": "http-e2e", "path": "hi.txt", "content": "hello"},
            )
            r = await client.call_tool(
                "read_file",
                {"session_id": "http-e2e", "path": "hi.txt"},
            )
            assert r.data == "hello"

    asyncio.run(scenario())


def test_mcp_tenant_isolation_over_http(live_server):
    # Two different bearer tokens must land in different tenant sandboxes
    # even when using the same session_id. Proves the contextvar is actually
    # per-request, not leaking across tasks.
    url = f"{live_server}/"

    def _client(token: str) -> Client:
        return Client(StreamableHttpTransport(url, headers={"Authorization": f"Bearer {token}"}))

    async def write_as(token: str, content: str):
        async with _client(token) as client:
            await client.call_tool(
                "write_file",
                {"session_id": "shared-name", "path": "x.txt", "content": content},
            )

    async def read_as(token: str) -> str:
        async with _client(token) as client:
            res = await client.call_tool(
                "read_file",
                {"session_id": "shared-name", "path": "x.txt"},
            )
            return res.data

    async def scenario():
        await write_as("key-a", "A-secret")
        await write_as("key-b", "B-secret")
        # Each tenant sees only its own file content at the same logical path.
        assert await read_as("key-a") == "A-secret"
        assert await read_as("key-b") == "B-secret"

    asyncio.run(scenario())
