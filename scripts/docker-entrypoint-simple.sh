#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# Startup banner
# ------------------------------------------------------------
echo "------------------------------------------------------------"
echo " Youtarr container starting"
echo "------------------------------------------------------------"
echo " Effective UID:GID : $(id -u):$(id -g)"
echo " Requested UID:GID : ${YOUTARR_UID:-unset}:${YOUTARR_GID:-unset}"
echo " Node version      : $(node --version 2>/dev/null || echo unknown)"
echo "------------------------------------------------------------"

# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------
YOUTARR_UID="${YOUTARR_UID:-1000}"
YOUTARR_GID="${YOUTARR_GID:-1000}"

CMD=("node" "server/server.js")

# ------------------------------------------------------------
# Signal handling
# ------------------------------------------------------------
NODE_PID=""

handle_shutdown() {
    echo "[youtarr] Shutdown signal received"

    if [ -n "$NODE_PID" ] && kill -0 "$NODE_PID" 2>/dev/null; then
        echo "[youtarr] Stopping Node.js (PID $NODE_PID)"
        kill -TERM "$NODE_PID" 2>/dev/null || true
        wait "$NODE_PID" 2>/dev/null || true
    fi

    echo "[youtarr] Shutdown complete"
    exit 0
}

trap handle_shutdown SIGTERM SIGINT

# ------------------------------------------------------------
# Root / privilege handling
# ------------------------------------------------------------
if [ "$YOUTARR_UID" = "0" ] || [ "$YOUTARR_GID" = "0" ]; then
    echo "[youtarr][WARN] Container is running as root (UID=0 / GID=0)"
    echo "[youtarr][WARN] This is NOT recommended for production"
    echo "[youtarr][WARN] Set YOUTARR_UID/YOUTARR_GID (e.g. 99:100 on unRAID)"
else
    echo "[youtarr] Dropping privileges to ${YOUTARR_UID}:${YOUTARR_GID}"
    chown -R "${YOUTARR_UID}:${YOUTARR_GID}" /config /data
    exec gosu "${YOUTARR_UID}:${YOUTARR_GID}" "$0" "$@"
fi

# ------------------------------------------------------------
# Database wait
# ------------------------------------------------------------
echo "[youtarr] Waiting for database..."

MAX_TRIES=30
TRIES=0

while [ "$TRIES" -lt "$MAX_TRIES" ]; do
    if node -e "
        const mysql = require('mysql2/promise');
        mysql.createConnection({
            host: process.env.DB_HOST || 'localhost',
            port: process.env.DB_PORT || 3321,
            user: process.env.DB_USER || 'root',
            password: process.env.DB_PASSWORD || '123qweasd',
            database: process.env.DB_NAME || 'youtarr'
        }).then(() => process.exit(0))
          .catch(() => process.exit(1));
    " >/dev/null 2>&1; then
        echo "[youtarr] Database is ready"
        break
    fi

    TRIES=$((TRIES + 1))
    echo "[youtarr] Waiting for database... (${TRIES}/${MAX_TRIES})"
    sleep 2
done

if [ "$TRIES" -eq "$MAX_TRIES" ]; then
    echo "[youtarr][ERROR] Database not reachable after ${MAX_TRIES} attempts"
    exit 1
fi

# ------------------------------------------------------------
# Start Node.js
# ------------------------------------------------------------
echo "[youtarr] Starting Node.js server..."
"${CMD[@]}" &
NODE_PID=$!

echo "[youtarr] Node.js started (PID $NODE_PID)"

# ------------------------------------------------------------
# Wait
# ------------------------------------------------------------
wait "$NODE_PID"
echo "[youtarr][ERROR] Node.js exited unexpectedly"
exit 1
