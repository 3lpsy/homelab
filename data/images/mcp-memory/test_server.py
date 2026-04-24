"""
Unit tests for mcp-memory server.py.

Runs the tool functions directly (bypassing FastMCP dispatch) with a
manually populated api-key ContextVar. Run with `pytest test_server.py`.
"""
import asyncio
import json
import os
import pathlib
import shutil
import tempfile

_TMP = tempfile.mkdtemp(prefix="mcpmem-test-")
os.environ["MCP_PATH_SALT"] = "unit-test-salt"
os.environ["MCP_DATA_ROOT"] = _TMP
os.environ["MCP_API_KEYS"] = "key-a,key-b,key-c"
os.environ.setdefault("LOG_LEVEL", "error")

import pytest  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402
from pydantic import ValidationError  # noqa: E402

import server  # noqa: E402
from server import (  # noqa: E402
    Entity,
    ObservationAdd,
    ObservationDelete,
    Relation,
)


def _call(coro):
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def _wipe_data_root():
    # Reset tenant storage and the api-key contextvar between tests so
    # writes / state from one test don't leak into the next via the shared
    # MCP_DATA_ROOT or module-level ContextVar.
    yield
    root = pathlib.Path(_TMP)
    if root.exists():
        for child in root.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)
    server._api_key_ctx.set("")


@pytest.fixture
def key_a():
    tok = server._api_key_ctx.set("key-a")
    try:
        yield "key-a"
    finally:
        server._api_key_ctx.reset(tok)


@pytest.fixture
def key_b():
    tok = server._api_key_ctx.set("key-b")
    try:
        yield "key-b"
    finally:
        server._api_key_ctx.reset(tok)


# --- hashing / tenant dirs ---------------------------------------------------


def test_hash_deterministic():
    assert server._hash("x") == server._hash("x")
    assert server._hash("x") != server._hash("y")


def test_tenant_dir_requires_api_key():
    # Fresh context
    assert server._api_key_ctx.get() in ("", None)
    with pytest.raises(PermissionError):
        server._tenant_dir()


def test_tenant_dir_per_key(key_a):
    a = server._tenant_dir()
    server._api_key_ctx.set("key-b")
    b = server._tenant_dir()
    assert a != b


# --- pydantic validation -----------------------------------------------------


def test_relation_accepts_from_alias():
    r = Relation.model_validate({"from": "a", "to": "b", "relationType": "knows"})
    assert r.from_ == "a"


def test_relation_serializes_as_from():
    r = Relation(from_="a", to="b", relationType="knows")
    dumped = r.model_dump()
    assert dumped == {"from": "a", "to": "b", "relationType": "knows"}


def test_entity_rejects_unknown_field():
    with pytest.raises(ValidationError):
        Entity.model_validate({"name": "a", "entityType": "t", "bogus": 1})


def test_entity_rejects_empty_name():
    with pytest.raises(ValidationError):
        Entity.model_validate({"name": "", "entityType": "t"})


def test_relation_rejects_empty_fields():
    with pytest.raises(ValidationError):
        Relation.model_validate({"from": "", "to": "b", "relationType": "knows"})


# --- create / read round-trip ------------------------------------------------


def test_create_entities_and_read_graph(key_a):
    added = _call(server.create_entities([
        Entity(name="alice", entityType="person", observations=["likes tea"]),
        Entity(name="bob", entityType="person"),
    ]))
    assert {e.name for e in added} == {"alice", "bob"}

    g = _call(server.read_graph())
    assert {e.name for e in g.entities} == {"alice", "bob"}
    assert g.relations == []


def test_create_entities_dedupes_by_name(key_a):
    _call(server.create_entities([Entity(name="alice", entityType="person")]))
    added = _call(server.create_entities([
        Entity(name="alice", entityType="person-v2"),  # dup — skipped
        Entity(name="carol", entityType="person"),
    ]))
    assert [e.name for e in added] == ["carol"]
    g = _call(server.read_graph())
    alice = next(e for e in g.entities if e.name == "alice")
    # Original entityType preserved; duplicate was a no-op.
    assert alice.entityType == "person"


def test_create_relations_dedupes(key_a):
    _call(server.create_entities([
        Entity(name="a", entityType="x"),
        Entity(name="b", entityType="x"),
    ]))
    _call(server.create_relations([Relation(from_="a", to="b", relationType="knows")]))
    added = _call(server.create_relations([
        Relation(from_="a", to="b", relationType="knows"),  # dup
        Relation(from_="a", to="b", relationType="trusts"),
    ]))
    assert [(r.from_, r.to, r.relationType) for r in added] == [("a", "b", "trusts")]
    g = _call(server.read_graph())
    assert len(g.relations) == 2


# --- observations ------------------------------------------------------------


def test_add_observations_appends_unique(key_a):
    _call(server.create_entities([Entity(name="a", entityType="x", observations=["one"])]))
    out = _call(server.add_observations([
        ObservationAdd(entityName="a", contents=["one", "two", "three"]),
    ]))
    assert out == [{"entityName": "a", "addedObservations": ["two", "three"]}]
    g = _call(server.read_graph())
    assert next(e for e in g.entities if e.name == "a").observations == ["one", "two", "three"]


def test_add_observations_unknown_entity_raises(key_a):
    with pytest.raises(ToolError):
        _call(server.add_observations([ObservationAdd(entityName="ghost", contents=["x"])]))


def test_delete_observations(key_a):
    _call(server.create_entities([Entity(
        name="a", entityType="x", observations=["one", "two", "three"],
    )]))
    out = _call(server.delete_observations([
        ObservationDelete(entityName="a", observations=["two", "missing"]),
    ]))
    assert out == {"observationsRemoved": 1}
    g = _call(server.read_graph())
    assert next(e for e in g.entities if e.name == "a").observations == ["one", "three"]


# --- deletions ---------------------------------------------------------------


def test_delete_entities_removes_touching_relations(key_a):
    _call(server.create_entities([
        Entity(name="a", entityType="x"),
        Entity(name="b", entityType="x"),
        Entity(name="c", entityType="x"),
    ]))
    _call(server.create_relations([
        Relation(from_="a", to="b", relationType="knows"),
        Relation(from_="b", to="c", relationType="knows"),
    ]))
    res = _call(server.delete_entities(["b"]))
    assert res == {"entitiesRemoved": 1, "relationsRemoved": 2}
    g = _call(server.read_graph())
    assert {e.name for e in g.entities} == {"a", "c"}
    assert g.relations == []


def test_delete_relations_specific_triple(key_a):
    _call(server.create_entities([
        Entity(name="a", entityType="x"),
        Entity(name="b", entityType="x"),
    ]))
    _call(server.create_relations([
        Relation(from_="a", to="b", relationType="knows"),
        Relation(from_="a", to="b", relationType="trusts"),
    ]))
    res = _call(server.delete_relations([Relation(from_="a", to="b", relationType="knows")]))
    assert res == {"relationsRemoved": 1}
    g = _call(server.read_graph())
    assert [r.relationType for r in g.relations] == ["trusts"]


# --- search / open -----------------------------------------------------------


def test_search_nodes_matches_name_type_observations(key_a):
    _call(server.create_entities([
        Entity(name="alice", entityType="person", observations=["drinks tea"]),
        Entity(name="bob", entityType="person", observations=["likes coffee"]),
        Entity(name="desk", entityType="object"),
    ]))
    _call(server.create_relations([
        Relation(from_="alice", to="bob", relationType="knows"),
    ]))
    hit = _call(server.search_nodes("TEA"))  # case-insensitive
    assert [e.name for e in hit.entities] == ["alice"]

    both = _call(server.search_nodes("person"))
    assert {e.name for e in both.entities} == {"alice", "bob"}
    # Relation surfaces because both endpoints matched.
    assert [(r.from_, r.to) for r in both.relations] == [("alice", "bob")]


def test_open_nodes_returns_connecting_relations(key_a):
    _call(server.create_entities([
        Entity(name="a", entityType="x"),
        Entity(name="b", entityType="x"),
        Entity(name="c", entityType="x"),
    ]))
    _call(server.create_relations([
        Relation(from_="a", to="b", relationType="knows"),
        Relation(from_="a", to="c", relationType="knows"),
    ]))
    g = _call(server.open_nodes(["a", "b"]))
    assert {e.name for e in g.entities} == {"a", "b"}
    # Only a→b — a→c drops because `c` isn't in the opened set.
    assert [(r.from_, r.to) for r in g.relations] == [("a", "b")]


# --- tenant isolation --------------------------------------------------------


def test_tenant_isolation():
    server._api_key_ctx.set("key-a")
    _call(server.create_entities([Entity(name="a-only", entityType="x")]))

    server._api_key_ctx.set("key-b")
    g = _call(server.read_graph())
    assert g.entities == []
    assert g.relations == []

    server._api_key_ctx.set("key-a")
    g = _call(server.read_graph())
    assert [e.name for e in g.entities] == ["a-only"]


# --- NDJSON persistence ------------------------------------------------------


def test_ndjson_format_on_disk(key_a):
    _call(server.create_entities([Entity(name="a", entityType="x", observations=["o1"])]))
    _call(server.create_relations([Relation(from_="a", to="a", relationType="self")]))
    p = server._memory_path()
    lines = [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    # All lines carry a `type` tag. Relation line uses `from`, not `from_`.
    assert lines[0]["type"] == "entity"
    assert lines[0]["name"] == "a"
    assert lines[1]["type"] == "relation"
    assert lines[1]["from"] == "a"
    assert "from_" not in lines[1]


def test_load_graph_tolerates_junk_lines(key_a):
    p = server._memory_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        "\n"
        "{\"type\":\"entity\",\"name\":\"a\",\"entityType\":\"x\",\"observations\":[]}\n"
        "not json at all\n"
        "{\"type\":\"mystery\",\"foo\":1}\n"
        "{\"type\":\"relation\",\"from\":\"a\",\"to\":\"a\",\"relationType\":\"self\"}\n"
    )
    g = server.load_graph()
    assert [e.name for e in g.entities] == ["a"]
    assert [(r.from_, r.to) for r in g.relations] == [("a", "a")]


def test_save_graph_size_cap(key_a, monkeypatch):
    monkeypatch.setattr(server, "MCP_MAX_GRAPH_BYTES", 50)
    big_obs = ["x" * 200]
    with pytest.raises(ToolError):
        _call(server.create_entities([
            Entity(name="whale", entityType="x", observations=big_obs),
        ]))
    # No corrupt .tmp leftover, no persisted file.
    p = server._memory_path()
    if p.parent.exists():
        leftovers = list(p.parent.glob("memory.jsonl.*.tmp"))
        assert leftovers == []


# --- auth middleware --------------------------------------------------------


def test_auth_rejects_missing_bearer():
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    mw = server.AuthMiddleware(lambda *a, **kw: None)
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/mcp/",
        "query_string": b"",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    }
    asyncio.run(mw(scope, _recv, _send))
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 401


def test_auth_accepts_valid_bearer_and_binds_contextvar():
    captured: list[str] = []

    async def inner(scope, receive, send):
        # The contextvar must be set by the time the inner app runs.
        captured.append(server._api_key_ctx.get())
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    async def _send(msg):
        pass

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    mw = server.AuthMiddleware(inner)
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/mcp/",
        "query_string": b"",
        "headers": [(b"authorization", b"Bearer key-a")],
        "client": ("1.2.3.4", 1234),
    }
    asyncio.run(mw(scope, _recv, _send))
    assert captured == ["key-a"]
    # And it resets on the way out.
    assert server._api_key_ctx.get() in ("", None)


# --- instructions wiring -----------------------------------------------------


def test_instructions_present_on_server():
    # FastMCP stores constructor `instructions=` and surfaces it via
    # initialize → serverInfo.instructions. OSS clients inject it into the
    # system prompt before tool use, so a regression to empty/absent silently
    # drops workflow guidance for low-tier models.
    inst = getattr(server.mcp, "instructions", None) or ""
    assert inst.strip(), "FastMCP('memory') must carry an instructions block"
    # Anchor on the hazards an OSS model needs spelled out.
    assert "create_entities" in inst
    assert "add_observations" in inst
    assert "search_nodes" in inst
    # "Create is not upsert" is the biggest foot-gun — make sure it stays
    # in the text.
    assert "skipped" in inst.lower() or "silent" in inst.lower()
    # Wire-format note for the from/from_ trap.
    assert "`from`" in inst


def test_auth_accepts_query_param_key():
    captured: list[str] = []

    async def inner(scope, receive, send):
        captured.append(server._api_key_ctx.get())
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    async def _send(msg):
        pass

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    mw = server.AuthMiddleware(inner)
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/mcp/",
        "query_string": b"api_key=key-b",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    }
    asyncio.run(mw(scope, _recv, _send))
    assert captured == ["key-b"]
