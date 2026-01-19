FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        libicu-dev \
        libpq-dev \
        osm2pgsql \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/nominatim
COPY . /opt/nominatim

RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir \
        ./packaging/nominatim-db \
        ./packaging/nominatim-api \
    && python3 -m pip install --no-cache-dir \
        uvicorn \
        falcon \
        starlette

RUN useradd -m -u 1000 -d /var/lib/nominatim nominatim \
    && mkdir -p /var/lib/nominatim \
    && chown -R nominatim:nominatim /var/lib/nominatim

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER nominatim
ENV NOMINATIM_PROJECT_DIR=/var/lib/nominatim
WORKDIR /var/lib/nominatim

EXPOSE 8088
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve", "--server", "0.0.0.0:8088", "--engine", "falcon"]
