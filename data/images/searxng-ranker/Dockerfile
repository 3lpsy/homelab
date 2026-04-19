FROM python:3.11-alpine

RUN pip install --no-cache-dir \
      "httpx>=0.27" \
      "kubernetes>=28" \
      "PyYAML>=6"

EXPOSE 8090

ENTRYPOINT ["python3", "/app/searxng-ranker.py"]
