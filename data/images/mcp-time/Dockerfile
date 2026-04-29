FROM python:3.14-alpine

# tzdata: zoneinfo needs the IANA tzdb, which python:alpine ships without. The
# pip-installed `tzdata` package is a pure-Python mirror of the tzdb that
# zoneinfo picks up automatically.
RUN pip install --no-cache-dir \
      "fastmcp>=2.0" \
      "uvicorn>=0.30" \
      "pydantic>=2.0" \
      "tzdata>=2024.1"

WORKDIR /app

# Shared bootstrap package. The build context lands `mcp_common/` as a real
# directory thanks to the buildkit-job module's `context_dirs` input
# (ConfigMap items[].path remap). COPY before server.py so a tools-only
# server.py change does not bust this layer's cache.
COPY mcp_common ./mcp_common
COPY server.py /app/server.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    MCP_DEFAULT_TIMEZONE=America/Chicago \
    PYTHONDONTWRITEBYTECODE=1

RUN addgroup -g 1000 mcp && adduser -D -u 1000 -G mcp mcp
USER mcp

EXPOSE 8000

CMD ["python", "server.py"]
