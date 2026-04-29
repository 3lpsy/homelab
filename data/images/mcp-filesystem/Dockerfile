FROM python:3.14-alpine

RUN pip install --no-cache-dir \
      "fastmcp>=2.0" \
      "uvicorn>=0.30"

WORKDIR /app

# Shared bootstrap package. The build context lands `mcp_common/` as a real
# directory thanks to the buildkit-job module's `context_dirs` input
# (ConfigMap items[].path remap). COPY before server.py so a tools-only
# server.py change does not bust this layer's cache.
COPY mcp_common ./mcp_common
COPY server.py /app/server.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    MCP_DATA_ROOT=/data \
    PYTHONDONTWRITEBYTECODE=1

RUN addgroup -g 1000 mcp && adduser -D -u 1000 -G mcp mcp
USER mcp

EXPOSE 8000

CMD ["python", "server.py"]
