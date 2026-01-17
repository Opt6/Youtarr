# ---- Base Node ----
FROM node:20-slim AS base
WORKDIR /app

# ---- Dependencies ----
FROM base AS dependencies
COPY package*.json ./
# Skip prepare script (husky) for production dependencies
RUN npm ci --only=production --ignore-scripts

# ---- Build ----
FROM base AS build
COPY package*.json ./
RUN npm ci
# Copy server code and built React app
COPY server/ ./server/
COPY client/build/ ./client/build/
COPY migrations/ ./migrations/

# ---- Apprise ----
FROM python:3.11-slim AS apprise
RUN pip install --no-cache-dir --target=/opt/apprise apprise

# ---- Release ----
FROM node:20-slim AS release
WORKDIR /app

# Install runtime dependencies and gosu for privilege drop
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    unzip \
    python3 \
    ca-certificates \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Download the latest yt-dlp release directly from GitHub
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && \
    chmod +x /usr/local/bin/yt-dlp

# Install Deno
ENV DENO_INSTALL="/usr/local"
RUN curl -fsSL https://deno.land/install.sh | sh

# ---- User / Permissions (1000 by default) ----
# -- NOTE:
# -- unRAID users should override via env: 99:100
# -- Runtime privilege drop is handled by gosu in entrypoint

# Build-time user
ARG YOUTARR_UID=1000
ARG YOUTARR_GID=1000
ENV YOUTARR_UID=${YOUTARR_UID} \
    YOUTARR_GID=${YOUTARR_GID}

# Create non-root youtarr user and group
RUN groupadd -g ${YOUTARR_GID} youtarr || true && \
    useradd -m -u ${YOUTARR_UID} -g ${YOUTARR_GID} youtarr || true && \
    mkdir -p /config /data

# Copy Apprise from builder stage
COPY --from=apprise /opt/apprise /opt/apprise
ENV PYTHONPATH="/opt/apprise"

# Create apprise wrapper (the pip-installed script has wrong shebang for this image)
RUN printf '#!/bin/sh\nexec python3 -c "from apprise.cli import main; main()" "$@"\n' > /usr/local/bin/apprise && \
    chmod +x /usr/local/bin/apprise

# Copy production node_modules
COPY --from=dependencies /app/node_modules ./node_modules

# Copy application files
COPY --from=build /app/server ./server
COPY --from=build /app/client/build ./client/build
COPY --from=build /app/migrations ./migrations
COPY --from=build /app/package.json ./package.json

# Copy config.example.json to server directory (guaranteed to exist and accessible)
COPY config/config.example.json /app/server/config.example.json

# Copy the new simplified entrypoint script
COPY scripts/docker-entrypoint-simple.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose port for the application
EXPOSE 3011

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD curl --fail --silent --show-error --output /dev/null http://localhost:3011/api/health || exit 1

# Run entrypoint (privilege drop handled inside script)
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "server/server.js"]
