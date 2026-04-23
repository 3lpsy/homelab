FROM python:3.14-alpine

RUN pip install --no-cache-dir \
      "starlette>=0.40" \
      "uvicorn>=0.30" \
      "httpx>=0.27"

WORKDIR /app
COPY auth_gate.py /app/auth_gate.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    UPSTREAM_URL=http://127.0.0.1:8080 \
    PYTHONDONTWRITEBYTECODE=1

RUN addgroup -g 1000 mcp && adduser -D -u 1000 -G mcp mcp
USER mcp

EXPOSE 8000

CMD ["python", "auth_gate.py"]
