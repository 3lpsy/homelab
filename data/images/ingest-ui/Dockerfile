FROM python:3.14-alpine AS base

# Runtime-only system deps. ffmpeg is needed by yt-dlp's audio extraction
# (-x --audio-format opus invokes ffmpeg as a postprocessor).
RUN apk add --no-cache ffmpeg ca-certificates


FROM base AS builder

# Toolchain only used while compiling C extensions (bcrypt, httptools,
# uvloop). Discarded when we copy /install into the runtime stage.
RUN apk add --no-cache gcc musl-dev libffi-dev

RUN pip install --no-cache-dir --prefix=/install \
        fastapi==0.115.* \
        uvicorn[standard]==0.32.* \
        python-multipart==0.0.* \
        yt-dlp==2025.10.*


FROM base AS runtime

COPY --from=builder /install /usr/local

WORKDIR /app
COPY server.py /app/server.py
COPY index.html /app/index.html
COPY test_server.py /app/test_server.py

RUN adduser -D -u 1000 app \
    && chown -R 1000:1000 /app

USER 1000:1000

EXPOSE 8000

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
