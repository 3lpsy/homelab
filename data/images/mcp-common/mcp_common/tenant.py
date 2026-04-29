"""Per-tenant on-disk sandbox helpers shared by mcp-filesystem and mcp-memory.

Both servers mount the same `mcp_data` PVC and isolate per-bearer data
under `<root>/<hash(salt + bearer)>/...`. Salt and root come from env so
the layout is identical across the two servers — moving the hash into a
shared module forecloses any chance of drift breaking cross-server PVC
sharing.
"""

from __future__ import annotations

import hashlib
import os
import pathlib


def init_tenant_root(
    *,
    salt_env: str = "MCP_PATH_SALT",
    root_env: str = "MCP_DATA_ROOT",
    default_root: str = "/data",
) -> tuple[bytes, pathlib.Path]:
    salt = os.environ.get(salt_env, "").encode()
    if not salt:
        raise SystemExit(f"{salt_env} must be set")
    root = pathlib.Path(os.environ.get(root_env, default_root)).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return salt, root


def hash_tenant(salt: bytes, value: str) -> str:
    # 128-bit truncation: collision risk is birthday ~2^64, fine for a
    # salted directory name. Not a credential hash.
    return hashlib.sha256(salt + value.encode()).hexdigest()[:32]
