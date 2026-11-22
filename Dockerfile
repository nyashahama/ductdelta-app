FROM node:24.15.0-bookworm-slim AS frontend
WORKDIR /build
RUN corepack enable
COPY frontend/ ./
RUN pnpm install --frozen-lockfile && pnpm run build

FROM rust:1.94.1-bookworm AS backend
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=frontend /build/.output/public /opt/ductdelta/public
COPY --from=backend /build/target/release/ductdelta /usr/local/bin/ductdelta
ENV DUCTDELTA_RAILWAY=1 \
    DUCTDELTA_WEB_DIST=/opt/ductdelta/public \
    PORT=8080
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ductdelta", "serve"]
