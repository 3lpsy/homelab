FROM python:3.11-alpine

RUN pip install --no-cache-dir \
      "mcp>=1.2" \
      "httpx>=0.27" \
      "uvicorn>=0.30"

WORKDIR /app
COPY server.py /app/server.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    SEARXNG_URL=http://localhost:8080

EXPOSE 8000

CMD ["python", "server.py"]
