FROM python:3.14-alpine

# uv for the cooldown-aware install + the `uv run` entrypoint. Pinned to the
# in-tree uv version (matches data/images/frigate-model).
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/uv
# 7-day PyPI publish cooldown — uv refuses any dep published more recently.
# Threaded from var.pip_proxy_cooldown_value via the BuildKit build-arg.
ARG UV_EXCLUDE_NEWER="7 days"
ENV UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER}

RUN uv pip install --system --no-cache \
      "httpx>=0.27" \
      "kubernetes>=28" \
      "PyYAML>=6"

EXPOSE 8090

ENTRYPOINT ["uv", "run", "--no-project", "python3", "/app/searxng-ranker.py"]
