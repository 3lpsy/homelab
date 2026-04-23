FROM python:3.14-alpine

RUN pip install --no-cache-dir \
      "fastmcp>=2.0" \
      "uvicorn>=0.30"

WORKDIR /app
COPY server.py /app/server.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    MCP_DATA_ROOT=/data \
    PYTHONDONTWRITEBYTECODE=1

RUN addgroup -g 1000 mcp && adduser -D -u 1000 -G mcp mcp
USER mcp

EXPOSE 8000

CMD ["python", "server.py"]
