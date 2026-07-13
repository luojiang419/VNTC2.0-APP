ARG RUST_VERSION=1.95.0
FROM ubuntu:24.04 AS builder

ARG RUST_VERSION
ARG VNTC_BUILD_TIME=not-injected

RUN apt-get update \
    && apt-get install --yes --no-install-recommends curl clang libclang-dev cmake pkg-config git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}"

ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /src
COPY linux_webui ./linux_webui
COPY vendor/vnt-core-2.0.0 ./vendor/vnt-core-2.0.0
COPY vendor/tun-rs-2.5.7 ./vendor/tun-rs-2.5.7

RUN cargo test --manifest-path linux_webui/Cargo.toml --locked --all-targets \
    && VNTC_BUILD_TIME="${VNTC_BUILD_TIME}" cargo build --manifest-path linux_webui/Cargo.toml --release --locked

FROM ubuntu:24.04 AS runtime

ARG APP_VERSION=4.5
LABEL org.opencontainers.image.title="VNTC Linux WebUI" \
      org.opencontainers.image.description="VNTC P2P Linux service with embedded WebUI" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/luojiang419/VNTC2.0-APP" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0755 /opt/vntc /data

COPY --from=builder /src/linux_webui/target/release/vntc-linux-webui /usr/local/bin/vntc-linux-webui
COPY linux_webui/config.example.json /opt/vntc/config.example.json
COPY linux_webui/docker/entrypoint.sh /usr/local/bin/vntc-entrypoint

RUN chmod 0755 /usr/local/bin/vntc-linux-webui /usr/local/bin/vntc-entrypoint \
    && chmod 0644 /opt/vntc/config.example.json

ENV RUST_LOG=info \
    VNTC_CONFIG=/data/config.json

WORKDIR /data

VOLUME ["/data"]
EXPOSE 18080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:18080/api/health || exit 1

ENTRYPOINT ["/usr/local/bin/vntc-entrypoint"]
