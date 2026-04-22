FROM python:3.14-alpine

RUN pip install --no-cache-dir \
      "fastmcp>=2.0" \
      "uvicorn>=0.30" \
      "pydantic>=2.0" \
      "httpx>=0.27"

WORKDIR /app
COPY server.py /app/server.py

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000

EXPOSE 8000

CMD ["python", "server.py"]
