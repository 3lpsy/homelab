FROM nextcloud:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libbz2-dev \
    libgmp-dev \
  && docker-php-ext-install bz2 gmp bcmath \
  && apt-get purge -y --auto-remove libbz2-dev libgmp-dev \
  && rm -rf /var/lib/apt/lists/*
