# Ryot with Pro features
# Clones upstream, patches license check, builds from source
ARG RYOT_VERSION=main
ARG NODE_BASE_IMAGE=node:24.4.0-bookworm-slim
ARG RUST_BASE_IMAGE=rust:1.87-bookworm

# ============================================================
# Stage 1: Clone and Patch Source
# ============================================================
FROM alpine:3.21 AS source
ARG RYOT_VERSION
RUN apk add --no-cache git sed
WORKDIR /src

RUN git clone --depth 1 --branch ${RYOT_VERSION} https://github.com/IgnisDa/ryot.git .

# Patch: Replace the license validation function with one that always returns true
RUN sed -i '/^async fn get_is_server_key_validated/,/^}$/c\
async fn get_is_server_key_validated(_ss: \&Arc<SupportingService>) -> Result<bool> {\
    Ok(true)\
}' crates/utils/dependent/core/src/lib.rs

# Verify patch was applied
RUN grep -A2 "get_is_server_key_validated" crates/utils/dependent/core/src/lib.rs | head -5

# ============================================================
# Stage 2: Build Frontend
# ============================================================
FROM $NODE_BASE_IMAGE AS frontend-build-base
ENV MOON_TOOLCHAIN_FORCE_GLOBALS=true
WORKDIR /app
RUN apt update && apt install -y --no-install-recommends git curl ca-certificates xz-utils
RUN npm install -g @moonrepo/cli && moon --version

FROM frontend-build-base AS frontend-workspace
WORKDIR /app
COPY --from=source /src .
RUN moon docker scaffold frontend

FROM frontend-build-base AS frontend-builder
WORKDIR /app
COPY --from=frontend-workspace /app/.moon/docker/workspace .
RUN moon docker setup
COPY --from=frontend-workspace /app/.moon/docker/sources .
RUN moon run frontend:build
RUN moon docker prune

# ============================================================
# Stage 3: Build Backend (Rust)
# ============================================================
FROM $RUST_BASE_IMAGE AS backend-builder
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=source /src .

ENV APP_VERSION="self-hosted-pro"
ENV UNKEY_ROOT_KEY=""
RUN cargo build --release --locked

# ============================================================
# Stage 4: Final Runtime Image
# ============================================================
FROM $NODE_BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/IgnisDa/ryot"
LABEL org.opencontainers.image.description="Self-hosted Ryot with Pro features"

# Disable telemetry
ENV FRONTEND_UMAMI_SCRIPT_URL=""
ENV FRONTEND_UMAMI_WEBSITE_ID=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl ca-certificates procps libc6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=caddy:2.9.1 /usr/bin/caddy /usr/local/bin/caddy
RUN npm install --global concurrently@9.1.2 && concurrently --version

RUN useradd -m -u 1001 ryot
WORKDIR /home/ryot
USER ryot

COPY --from=source /src/ci/Caddyfile /etc/caddy/Caddyfile
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/node_modules ./node_modules
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/package.json ./package.json
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/build ./build
COPY --from=backend-builder --chown=ryot:ryot /app/target/release/backend /usr/local/bin/backend

CMD [ \
    "concurrently", "--names", "frontend,backend,proxy", "--kill-others", \
    "PORT=3000 npx react-router-serve ./build/server/index.js", \
    "BACKEND_PORT=5000 /usr/local/bin/backend", \
    "caddy run --config /etc/caddy/Caddyfile" \
]
