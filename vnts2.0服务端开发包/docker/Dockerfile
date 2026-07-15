# syntax=docker/dockerfile:1.7
FROM rust:1.95.0-bookworm AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends clang cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY official-vnts-source-2.0.0/Cargo.toml official-vnts-source-2.0.0/Cargo.lock official-vnts-source-2.0.0/build.rs ./
COPY official-vnts-source-2.0.0/proto ./proto
COPY official-vnts-source-2.0.0/src ./src
COPY official-vnts-source-2.0.0/static ./static
RUN cargo build --release --locked \
    && strip /build/target/release/vnts2

FROM debian:bookworm-slim AS runtime

ARG VERSION=2.0.0
LABEL org.opencontainers.image.title="VNTS 2.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.description="VNTS 2.0 virtual network server"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 vnts2 \
    && useradd --system --uid 10001 --gid 10001 --home-dir /data --shell /usr/sbin/nologin vnts2 \
    && install -d -m 0750 -o vnts2 -g vnts2 /data /opt/vnts2

COPY --from=builder --chown=root:root /build/target/release/vnts2 /opt/vnts2/vnts2
COPY --chown=root:root docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=root:root docker/config.example.toml /opt/vnts2/config.example.toml
COPY --chown=root:root docker/DOCKER-DEPLOY.md /opt/vnts2/DOCKER-DEPLOY.md
COPY --chown=root:root official-vnts-source-2.0.0/NOTICE /opt/vnts2/NOTICE
RUN chmod 0755 /opt/vnts2/vnts2 /usr/local/bin/docker-entrypoint.sh \
    && chmod 0644 /opt/vnts2/config.example.toml /opt/vnts2/DOCKER-DEPLOY.md /opt/vnts2/NOTICE

USER 10001:10001
WORKDIR /data
VOLUME ["/data"]
EXPOSE 29872/tcp 29872/udp 51820/udp 29873/udp

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=6 \
  CMD curl --fail --silent --show-error http://127.0.0.1:29871/ >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
