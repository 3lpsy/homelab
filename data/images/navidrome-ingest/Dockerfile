FROM python:3.14-alpine AS base

# Runtime needs the ffmpeg shared libs (libavcodec/libavformat/libavutil)
# for PyAV — they're pulled in by `apk add ffmpeg-libs`. We don't shell
# out to the ffmpeg binary anymore: audio-stream md5 is computed via
# PyAV directly.
RUN apk add --no-cache ffmpeg-libs ca-certificates


FROM base AS builder

# Toolchain + ffmpeg dev headers + pkgconfig for building PyAV against
# the system ffmpeg. aiohttp/litellm transitive sdists also need gcc.
RUN apk add --no-cache gcc musl-dev libffi-dev ffmpeg-dev pkgconfig

RUN pip install --no-cache-dir --prefix=/install \
        mutagen==1.47.* \
        "av>=17.0.0,<18" \
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
