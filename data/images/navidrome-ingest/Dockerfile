FROM python:3.14-alpine AS base

# Runtime-only system deps. ffmpeg is shelled out to by ffmpeg-python /
# mutagen-adjacent codepaths for probing edge-case files.
RUN apk add --no-cache ffmpeg ca-certificates


FROM base AS builder

# Toolchain only used while compiling C extensions (aiohttp accelerators,
# any litellm transitive deps that ship sdists). Discarded when we copy
# /install into the runtime stage.
RUN apk add --no-cache gcc musl-dev libffi-dev

RUN pip install --no-cache-dir --prefix=/install \
        mutagen==1.47.* \
        ffmpeg-python==0.2.* \
        litellm==1.55.* \
        aiohttp==3.10.* \
        jinja2==3.1.*
# httpx is left unpinned — litellm pulls a compatible 0.27.x; the worker's
# httpx.AsyncClient API is identical across 0.27 and 0.28.


FROM base AS runtime

COPY --from=builder /install /usr/local

WORKDIR /app
COPY worker.py /app/worker.py
COPY test_worker.py /app/test_worker.py

RUN adduser -D -u 1000 app \
    && chown -R 1000:1000 /app

USER 1000:1000

EXPOSE 8090

CMD ["python", "/app/worker.py"]
