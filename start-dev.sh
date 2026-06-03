#!/usr/bin/env bash
# start-dev.sh — Start the full ShareGrid network stack on a single machine.
#
# Usage: ./start-dev.sh [--no-build]
#
# Starts sharegrid-router and sharegrid-host as background containers, then
# becomes the sharegrid-user CLI session. Router and host keep running after
# the user exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROUTER_PORT=8443
HOST_PORT=9000
NETWORK=sharegrid-net
ROUTER_CONTAINER=sharegrid-router
HOST_CONTAINER=sharegrid-host
MODEL_FILE="sharegrid-host/models/Phi-3.5-mini-instruct-IQ2_M.gguf"

BUILD=1
if [[ "${1:-}" == "--no-build" ]]; then
  BUILD=0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[start-dev] $*"; }

# Stop and remove any container currently publishing a given host port.
clear_port() {
  local port="$1"
  local ids
  ids=$(docker ps --format "{{.ID}} {{.Ports}}" \
    | awk -v p=":${port}->" '$0 ~ p {print $1}')
  if [[ -n "$ids" ]]; then
    log "Stopping container(s) using port ${port}: ${ids}"
    echo "$ids" | xargs docker stop
    echo "$ids" | xargs docker rm
  fi
}

# ── Step 1: Cleanup ───────────────────────────────────────────────────────────

# Force-remove named containers first (covers running, paused, and — critically
# — "Exited" containers that are about to be restarted by --restart=on-failure).
# docker ps only shows running containers, so clear_port alone cannot catch a
# host that exited between restarts and would come back with a stale router URL.
log "Removing existing named containers (if any)..."
docker rm -f "$ROUTER_CONTAINER" 2>/dev/null || true
docker rm -f "$HOST_CONTAINER"   2>/dev/null || true

# Also evict any other containers that happen to be occupying the same ports.
log "Checking for port conflicts..."
clear_port "$ROUTER_PORT"
clear_port "$HOST_PORT"

# ── Step 2: Docker network ────────────────────────────────────────────────────

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  log "Creating Docker network: ${NETWORK}"
  docker network create "$NETWORK"
fi

# ── Step 3: Build images ──────────────────────────────────────────────────────

if [[ "$BUILD" -eq 1 ]]; then
  log "Building sharegrid-router..."
  docker build -t sharegrid-router "${SCRIPT_DIR}/sharegrid-router"

  log "Building sharegrid-host..."
  docker build \
    -f "${SCRIPT_DIR}/sharegrid-host/Dockerfile" \
    --build-arg "MODEL_FILE=${MODEL_FILE}" \
    -t sharegrid-host \
    "${SCRIPT_DIR}"

  log "Building sharegrid-user..."
  docker build -t sharegrid-user "${SCRIPT_DIR}/sharegrid-user"
else
  log "Skipping image builds (--no-build)."
fi

# ── Step 4: Start router ──────────────────────────────────────────────────────

log "Starting sharegrid-router..."
docker run -d \
  --name "$ROUTER_CONTAINER" \
  --network "$NETWORK" \
  -p "${ROUTER_PORT}:${ROUTER_PORT}" \
  -e SHAREGRID_LISTEN_ADDR="0.0.0.0:${ROUTER_PORT}" \
  sharegrid-router

# ── Step 5: Extract router URLs (host registration + user access) ─────────────
#
# After Phase 9 the router prints two separate URL blocks:
#
#   HOST REGISTRATION URLs (distribute only to host operators):
#     https://<ip>:<port>?fp=sha256:<hex>&key=<hostSecret>   [eth0]
#
#   USER ACCESS URLs (distribute only to end users):
#     https://<ip>:<port>?fp=sha256:<hex>&key=<userSecret>   [eth0]
#
# We extract the first non-loopback private-IP URL from each block separately.

log "Waiting for router startup banner..."
HOST_ROUTER_URL=""
USER_ROUTER_URL=""
URL_PATTERN='https://(10\.[0-9.]+|172\.[0-9.]+|192\.168\.[0-9.]+):[0-9]+\?fp=sha256:[0-9a-f]{64}&key=[A-Za-z0-9_-]+'

for i in $(seq 1 30); do
  LOGS=$(docker logs "$ROUTER_CONTAINER" 2>&1)

  HOST_ROUTER_URL=$(echo "$LOGS" \
    | grep -A 20 "HOST REGISTRATION URLs" \
    | grep -m 1 -oE "$URL_PATTERN" || true)

  USER_ROUTER_URL=$(echo "$LOGS" \
    | grep -A 20 "USER ACCESS URLs" \
    | grep -m 1 -oE "$URL_PATTERN" || true)

  if [[ -n "$HOST_ROUTER_URL" && -n "$USER_ROUTER_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$HOST_ROUTER_URL" || -z "$USER_ROUTER_URL" ]]; then
  log "ERROR: Router did not produce both startup URLs within 30s."
  log "Router logs:"
  docker logs "$ROUTER_CONTAINER" 2>&1 || true
  exit 1
fi

log "Host registration URL: ${HOST_ROUTER_URL}"
log "User access URL:       ${USER_ROUTER_URL}"

# ── Step 6: Start host ────────────────────────────────────────────────────────

log "Starting sharegrid-host..."
docker run -d \
  --name "$HOST_CONTAINER" \
  --network "$NETWORK" \
  --cap-drop ALL \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --security-opt no-new-privileges \
  --ipc=none \
  --restart=on-failure \
  -p "${HOST_PORT}:${HOST_PORT}" \
  -e SHAREGRID_ROUTER_URL="$HOST_ROUTER_URL" \
  -e SHAREGRID_LISTEN_PORT="$HOST_PORT" \
  sharegrid-host

log "Waiting for host to register with router..."
REGISTERED=0
for i in $(seq 1 60); do
  if docker logs "$HOST_CONTAINER" 2>&1 | grep -q '"registered with router"'; then
    REGISTERED=1
    break
  fi
  sleep 1
done

if [[ "$REGISTERED" -eq 0 ]]; then
  log "ERROR: Host did not register with the router within 60s."
  log "Host logs:"
  docker logs "$HOST_CONTAINER" 2>&1 || true
  exit 1
fi

log "Host registered. Starting user session."

# ── Step 7: Become the user CLI ───────────────────────────────────────────────

log "Launching sharegrid-user..."
exec docker run -it --rm \
  --network "$NETWORK" \
  -e SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
  sharegrid-user
