"""Knowledge-graph memory MCP server, sandboxed per-API-key.

Port of `@modelcontextprotocol/server-memory` using fastmcp v2 + pydantic.
The graph is persisted as NDJSON at
`$MCP_DATA_ROOT/<hash(api_key+salt)>/memory.jsonl`. One tenant per API key;
no cross-tenant visibility.

Environment:
  MCP_API_KEYS   CSV of accepted Bearer tokens. Empty/unset is fail-closed.
  MCP_PATH_SALT  Hex or base64 salt mixed into tenant hashes.
  MCP_DATA_ROOT  Backing directory (default /data). Shared with mcp-filesystem;
                 per-service salt means tenant dirs never collide.
  MCP_HOST       Bind host (default 0.0.0.0)
  MCP_PORT       Bind port (default 8000)
  MCP_MAX_GRAPH_BYTES  Persisted graph size ceiling (default 32 MiB).
  LOG_LEVEL      debug / info / warning / error (default info).
"""

import contextvars
import hashlib
import json
import logging
import os
import pathlib
import secrets

import uvicorn
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel, ConfigDict, Field, model_serializer
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
PATH_SALT = os.environ.get("MCP_PATH_SALT", "").encode()
DATA_ROOT = pathlib.Path(os.environ.get("MCP_DATA_ROOT", "/data")).resolve()
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))
MCP_MAX_GRAPH_BYTES = int(os.environ.get("MCP_MAX_GRAPH_BYTES", str(32 * 1024 * 1024)))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.ERROR),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("mcp-memory")

if not PATH_SALT:
    raise SystemExit("MCP_PATH_SALT must be set")

DATA_ROOT.mkdir(parents=True, exist_ok=True)
log.info("startup: data_root=%s api_keys=%d log_level=%s", DATA_ROOT, len(API_KEYS), LOG_LEVEL)

_api_key_ctx: contextvars.ContextVar[str] = contextvars.ContextVar("api_key", default="")


class Entity(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1)
    entityType: str = Field(min_length=1)
    observations: list[str] = Field(default_factory=list)


class Relation(BaseModel):
    # `from` is a Python keyword, hence the alias. `populate_by_name` lets
    # callers send either `from` (wire-compatible with the TS server) or
    # `from_` (usable from Python). The custom serializer pins output keys
    # to `from` so fastmcp, NDJSON, and MCP responses all emit the spec name.
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    from_: str = Field(alias="from", min_length=1)
    to: str = Field(min_length=1)
    relationType: str = Field(min_length=1)

    @model_serializer
    def _ser(self) -> dict:
        return {"from": self.from_, "to": self.to, "relationType": self.relationType}


class ObservationAdd(BaseModel):
    model_config = ConfigDict(extra="forbid")
    entityName: str = Field(min_length=1)
    contents: list[str]


class ObservationDelete(BaseModel):
    model_config = ConfigDict(extra="forbid")
    entityName: str = Field(min_length=1)
    observations: list[str]


class Graph(BaseModel):
    entities: list[Entity] = Field(default_factory=list)
    relations: list[Relation] = Field(default_factory=list)


mcp = FastMCP("memory")


def _hash(v: str) -> str:
    # 128-bit truncated SHA-256, matching the filesystem server. Not a
    # credential hash — just a stable directory name per API key.
    return hashlib.sha256(PATH_SALT + v.encode()).hexdigest()[:32]


def _tenant_dir() -> pathlib.Path:
    key = _api_key_ctx.get()
    if not key:
        log.error("tenant_dir: no api key in request context")
        raise PermissionError("no api key in request context")
    return DATA_ROOT / _hash(key)


def _memory_path() -> pathlib.Path:
    return _tenant_dir() / "memory.jsonl"


def _rel_key(r: Relation) -> tuple[str, str, str]:
    return (r.from_, r.to, r.relationType)


def load_graph() -> Graph:
    p = _memory_path()
    try:
        if not p.exists():
            return Graph()
        size = p.stat().st_size
    except OSError as e:
        log.error("load_graph: stat failed for %s: %s", p, e)
        raise ToolError("failed to access memory graph due to a storage error — contact admin")
    if size > MCP_MAX_GRAPH_BYTES:
        log.warning("load_graph: file oversized (%d > %d) for %s", size, MCP_MAX_GRAPH_BYTES, p)
        raise ToolError(
            f"memory graph is too large to load ({size} bytes, limit {MCP_MAX_GRAPH_BYTES}). "
            "Delete entities or observations, or ask the admin to raise MCP_MAX_GRAPH_BYTES."
        )
    entities: list[Entity] = []
    relations: list[Relation] = []
    try:
        f = p.open(encoding="utf-8")
    except OSError as e:
        log.error("load_graph: open failed for %s: %s", p, e)
        raise ToolError("failed to read memory graph due to a storage error — contact admin")
    with f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                log.error("memory.jsonl line %d malformed, skipping: %s", lineno, e)
                continue
            kind = rec.pop("type", None)
            try:
                if kind == "entity":
                    entities.append(Entity.model_validate(rec))
                elif kind == "relation":
                    relations.append(Relation.model_validate(rec))
                else:
                    log.warning("memory.jsonl line %d unknown type=%r, skipping", lineno, kind)
            except Exception as e:
                log.error("memory.jsonl line %d validation failed, skipping: %s", lineno, e)
    return Graph(entities=entities, relations=relations)


def save_graph(g: Graph) -> None:
    p = _memory_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        log.error("save_graph: mkdir failed for %s: %s", p.parent, e)
        raise ToolError("failed to prepare memory graph storage — contact admin")
    tmp = p.with_name(f"{p.name}.{secrets.token_hex(8)}.tmp")
    try:
        with tmp.open("w", encoding="utf-8") as f:
            for e in g.entities:
                f.write(json.dumps({"type": "entity", **e.model_dump()}, ensure_ascii=False))
                f.write("\n")
            for r in g.relations:
                f.write(json.dumps({"type": "relation", **r.model_dump()}, ensure_ascii=False))
                f.write("\n")
        size = tmp.stat().st_size
        if size > MCP_MAX_GRAPH_BYTES:
            log.warning("save_graph: write rejected (%d > %d) for %s", size, MCP_MAX_GRAPH_BYTES, p)
            tmp.unlink(missing_ok=True)
            raise ToolError(
                f"write would exceed memory graph size limit ({size} bytes, limit {MCP_MAX_GRAPH_BYTES}). "
                "Delete some entities or observations, or ask the admin to raise MCP_MAX_GRAPH_BYTES."
            )
        os.replace(tmp, p)
    except ToolError:
        raise
    except OSError as e:
        log.error("save_graph: storage error writing %s: %s", p, e)
        tmp.unlink(missing_ok=True)
        raise ToolError("failed to persist memory graph due to a storage error — contact admin")
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


@mcp.tool()
async def create_entities(entities: list[Entity]) -> list[Entity]:
    """Create entities. Existing names are skipped (idempotent)."""
    g = load_graph()
    have = {e.name for e in g.entities}
    added: list[Entity] = []
    for e in entities:
        if e.name in have:
            continue
        g.entities.append(e)
        have.add(e.name)
        added.append(e)
    save_graph(g)
    log.info("create_entities: added=%d skipped=%d", len(added), len(entities) - len(added))
    return added


@mcp.tool()
async def create_relations(relations: list[Relation]) -> list[Relation]:
    """Create relations. Duplicate (from, to, relationType) triples are skipped."""
    g = load_graph()
    have = {_rel_key(r) for r in g.relations}
    added: list[Relation] = []
    for r in relations:
        k = _rel_key(r)
        if k in have:
            continue
        g.relations.append(r)
        have.add(k)
        added.append(r)
    save_graph(g)
    log.info("create_relations: added=%d skipped=%d", len(added), len(relations) - len(added))
    return added


@mcp.tool()
async def add_observations(observations: list[ObservationAdd]) -> list[dict]:
    """Append observations to named entities. Returns per-entity added items."""
    g = load_graph()
    by_name = {e.name: e for e in g.entities}
    result: list[dict] = []
    for op in observations:
        ent = by_name.get(op.entityName)
        if ent is None:
            log.info("add_observations: unknown entity %r", op.entityName)
            raise ToolError(
                f"entity {op.entityName!r} does not exist — "
                "create it first with create_entities, or check spelling with read_graph/search_nodes"
            )
        existing = set(ent.observations)
        added = [c for c in op.contents if c not in existing]
        ent.observations.extend(added)
        result.append({"entityName": op.entityName, "addedObservations": added})
    save_graph(g)
    log.info("add_observations: %d entities touched", len(result))
    return result


@mcp.tool()
async def delete_entities(entityNames: list[str]) -> dict:
    """Delete entities by name. Also removes relations touching them."""
    g = load_graph()
    targets = set(entityNames)
    before_e, before_r = len(g.entities), len(g.relations)
    g.entities = [e for e in g.entities if e.name not in targets]
    g.relations = [r for r in g.relations if r.from_ not in targets and r.to not in targets]
    save_graph(g)
    removed = {
        "entitiesRemoved": before_e - len(g.entities),
        "relationsRemoved": before_r - len(g.relations),
    }
    log.info("delete_entities: %s", removed)
    return removed


@mcp.tool()
async def delete_observations(deletions: list[ObservationDelete]) -> dict:
    """Remove specific observations from named entities."""
    g = load_graph()
    by_name = {e.name: e for e in g.entities}
    total = 0
    for op in deletions:
        ent = by_name.get(op.entityName)
        if ent is None:
            continue
        drop = set(op.observations)
        kept = [o for o in ent.observations if o not in drop]
        total += len(ent.observations) - len(kept)
        ent.observations = kept
    save_graph(g)
    log.info("delete_observations: removed=%d", total)
    return {"observationsRemoved": total}


@mcp.tool()
async def delete_relations(relations: list[Relation]) -> dict:
    """Remove specific (from, to, relationType) relations."""
    g = load_graph()
    drop = {_rel_key(r) for r in relations}
    before = len(g.relations)
    g.relations = [r for r in g.relations if _rel_key(r) not in drop]
    removed = before - len(g.relations)
    save_graph(g)
    log.info("delete_relations: removed=%d", removed)
    return {"relationsRemoved": removed}


@mcp.tool()
async def read_graph() -> Graph:
    """Return the entire graph for the caller's tenant."""
    g = load_graph()
    log.info("read_graph: entities=%d relations=%d", len(g.entities), len(g.relations))
    return g


@mcp.tool()
async def search_nodes(query: str) -> Graph:
    """Substring match over entity name / entityType / observations.

    Returns matched entities plus any relations that touch at least one
    matched entity on both ends — mirrors the official server's semantics.
    """
    q = query.lower()
    g = load_graph()
    hits = [
        e for e in g.entities
        if q in e.name.lower()
        or q in e.entityType.lower()
        or any(q in o.lower() for o in e.observations)
    ]
    names = {e.name for e in hits}
    rels = [r for r in g.relations if r.from_ in names and r.to in names]
    log.info("search_nodes: query=%r hits=%d rels=%d", query, len(hits), len(rels))
    return Graph(entities=hits, relations=rels)


@mcp.tool()
async def open_nodes(names: list[str]) -> Graph:
    """Fetch named entities plus relations that touch at least one of them on both ends."""
    wanted = set(names)
    g = load_graph()
    ents = [e for e in g.entities if e.name in wanted]
    present = {e.name for e in ents}
    rels = [r for r in g.relations if r.from_ in present and r.to in present]
    log.info("open_nodes: asked=%d found=%d rels=%d", len(names), len(ents), len(rels))
    return Graph(entities=ents, relations=rels)


# Pure ASGI middleware — same reasoning as mcp-filesystem: BaseHTTPMiddleware
# would dispatch in a separate anyio task and lose the api-key contextvar.
class AuthMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return

        if scope["type"] != "http":
            log.warning("auth: rejecting non-http scope: %s", scope["type"])
            if scope["type"] == "websocket":
                await receive()
                await send({"type": "websocket.close", "code": 1008})
            return

        method = scope["method"]
        if method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        header = headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not token:
            token = QueryParams(scope["query_string"]).get("api_key", "").strip()

        ok = bool(token) and any(secrets.compare_digest(token, k) for k in API_KEYS)
        if not ok:
            client = scope.get("client")
            log.warning(
                "auth: rejected %s %r from %s",
                method, scope["path"], client[0] if client else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return

        ctx_token = _api_key_ctx.set(token)
        log.debug("auth: ok %s %r", method, scope["path"])
        try:
            await self.app(scope, receive, send)
        finally:
            _api_key_ctx.reset(ctx_token)


app = mcp.http_app(
    path="/",
    middleware=[Middleware(AuthMiddleware)],
)


if __name__ == "__main__":
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level=LOG_LEVEL.lower(), access_log=False)
