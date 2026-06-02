FROM python:3.14-alpine

ARG LEGO_VERSION=4.19.2

# lego: static go binary, fetched from upstream releases (no apk package).
RUN apk add --no-cache curl ca-certificates \
 && case "$(uname -m)" in \
      x86_64)  ARCH=amd64 ;; \
      aarch64) ARCH=arm64 ;; \
      *)       echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin lego \
 && chmod +x /usr/local/bin/lego \
 && lego --version

RUN pip install --no-cache-dir \
      "boto3>=1.34,<2" \
      "cryptography>=44,<46"

WORKDIR /app
COPY rotate.py /app/rotate.py

ENV WORK_DIR=/work \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN addgroup -g 1000 rotator && adduser -D -u 1000 -G rotator rotator \
 && mkdir -p /work && chown -R 1000:1000 /work /app
USER 1000:1000

ENTRYPOINT ["python3", "/app/rotate.py"]
