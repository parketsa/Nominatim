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
        curl \
        libicu-dev \
        libpq-dev \
        osm2pgsql \
        postgresql-client \
        wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/nominatim
COPY . /opt/nominatim

RUN for pkg in nominatim-db nominatim-api; do \
        for link in src data lib-lua lib-sql settings; do \
            path="packaging/${pkg}/${link}"; \
            if [ -f "$path" ]; then \
                target=$(cat "$path" | tr -d '\n'); \
                rm -f "$path"; \
                ln -s "$target" "$path"; \
            fi; \
        done; \
    done

RUN if [ ! -f data/country_osm_grid.sql.gz ]; then \
        wget -O data/country_osm_grid.sql.gz https://nominatim.org/data/country_grid.sql.gz; \
    fi

RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir \
        ./packaging/nominatim-db \
        ./packaging/nominatim-api \
        osmium \
    && /opt/venv/bin/pip install --no-cache-dir \
        uvicorn \
        falcon \
        starlette \
    && chmod +x /opt/venv/bin/nominatim

RUN useradd -m -u 1000 -d /var/lib/nominatim nominatim \
    && mkdir -p /var/lib/nominatim /nominatim/data /var/cache/nominatim \
    && chown -R nominatim:nominatim /var/lib/nominatim /nominatim /var/cache/nominatim

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY utils/nominatim-env.sh /usr/local/bin/nominatim-env.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/nominatim-env.sh

USER nominatim
ENV HOME=/var/lib/nominatim
ENV PATH=/opt/venv/bin:$PATH
ENV NOMINATIM_PROJECT_DIR=/nominatim/data
WORKDIR /nominatim/data

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve", "--server", "0.0.0.0:8080", "--engine", "falcon"]
