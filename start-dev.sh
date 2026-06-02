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

# ── Step 1: Port conflict cleanup ─────────────────────────────────────────────

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

# ── Step 5: Extract router URL ────────────────────────────────────────────────

log "Waiting for router startup banner..."
ROUTER_URL=""
for i in $(seq 1 30); do
  ROUTER_URL=$(docker logs "$ROUTER_CONTAINER" 2>&1 \
    | grep -oE 'https://(10\.[0-9.]+|172\.[0-9.]+|192\.168\.[0-9.]+):[0-9]+\?fp=sha256:[0-9a-f]{64}' \
    | head -1 || true)
  if [[ -n "$ROUTER_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$ROUTER_URL" ]]; then
  log "ERROR: Router did not produce a startup URL within 30s."
  log "Router logs:"
  docker logs "$ROUTER_CONTAINER" 2>&1 || true
  exit 1
fi

log "Router URL: ${ROUTER_URL}"

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
  -e SHAREGRID_ROUTER_URL="$ROUTER_URL" \
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
  -e SHAREGRID_ROUTER_URL="$ROUTER_URL" \
  sharegrid-user
