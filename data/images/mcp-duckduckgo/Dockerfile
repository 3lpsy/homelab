FROM python:3.11-alpine

RUN pip install --no-cache-dir duckduckgo-mcp-server

ENV FASTMCP_HOST=0.0.0.0
ENV FASTMCP_PORT=8000

EXPOSE 8000

# Upstream `FastMCP("ddg-search")` is constructed without host/port, and
# FastMCP's __init__ passes its default "127.0.0.1" as an explicit kwarg to
# Settings — which overrides FASTMCP_HOST/FASTMCP_PORT env vars (pydantic-settings
# precedence: init args > env). Mutate settings after import, then run.
CMD ["python", "-c", "import duckduckgo_mcp_server.server as s; s.mcp.settings.host='0.0.0.0'; s.mcp.settings.port=8000; s.mcp.run(transport='streamable-http')"]
