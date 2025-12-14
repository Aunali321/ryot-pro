# Ryot with Pro features
# Clones upstream, patches license check, builds from source

ARG RYOT_VERSION=main
ARG NODE_BASE_IMAGE=node:24.4.0-bookworm-slim
ARG RUST_BASE_IMAGE=rust:1.87-bookworm

# ============================================================
# Stage 1: Build Frontend (with patched source)
# ============================================================
FROM $NODE_BASE_IMAGE AS frontend-builder
ARG RYOT_VERSION
ENV MOON_TOOLCHAIN_FORCE_GLOBALS=true
WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g @moonrepo/cli && moon --version

# Clone upstream
RUN git clone --depth 1 --branch ${RYOT_VERSION} https://github.com/IgnisDa/ryot.git .

# Patch: Replace the license validation function
RUN sed -i '/^async fn get_is_server_key_validated/,/^}$/c\
async fn get_is_server_key_validated(_ss: \&Arc<SupportingService>) -> Result<bool> {\
    Ok(true)\
}' crates/utils/dependent/core/src/lib.rs

# Verify patch
RUN grep -A2 "get_is_server_key_validated" crates/utils/dependent/core/src/lib.rs | head -5

# Build frontend using moon
RUN moon run frontend:build

# ============================================================
# Stage 2: Build Backend (Rust)
# ============================================================
FROM $RUST_BASE_IMAGE AS backend-builder
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Copy patched source from frontend stage
COPY --from=frontend-builder /app .

ENV APP_VERSION="self-hosted-pro"
ENV UNKEY_ROOT_KEY=""
RUN cargo build --release --locked

# ============================================================
# Stage 3: Final Runtime Image
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

# Copy Caddyfile BEFORE switching to non-root user
COPY --from=frontend-builder /app/ci/Caddyfile /etc/caddy/Caddyfile

# Create user and set up home directory
RUN useradd -m -u 1001 ryot
WORKDIR /home/ryot

# Copy app files with proper ownership
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/node_modules ./node_modules
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/package.json ./package.json
COPY --from=frontend-builder --chown=ryot:ryot /app/apps/frontend/build ./build
COPY --from=backend-builder --chown=ryot:ryot /app/target/release/backend /usr/local/bin/backend

# Switch to non-root user
USER ryot

CMD [ \
    "concurrently", "--names", "frontend,backend,proxy", "--kill-others", \
    "PORT=3000 npx react-router-serve ./build/server/index.js", \
    "BACKEND_PORT=5000 /usr/local/bin/backend", \
    "caddy run --config /etc/caddy/Caddyfile" \
]
