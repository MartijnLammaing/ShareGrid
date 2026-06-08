#!/usr/bin/env bash
# start-dev.sh — Start the full ShareGrid network stack on a single machine.
#
# Usage: ./start-dev.sh [--no-build] [--server]
#
# Default (no --server):
#   Starts sharegrid-router and sharegrid-host as background containers, then
#   becomes the sharegrid-user interactive CLI session. Router and host keep
#   running after the user exits.
#
# --server:
#   Starts router + host + sharegrid-user HTTP adapter as background containers.
#   The adapter exposes an OpenAI-compatible API on port 3000 for use as an
#   OpenCode provider. Prints the opencode.json snippet and exits; all three
#   containers keep running.
#   Stop all: docker rm -f sharegrid-router sharegrid-host sharegrid-user
#
# Flags can appear in any order and are independent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROUTER_PORT=8443
HOST_PORT=9000
USER_SERVER_PORT=3000
NETWORK=sharegrid-net
ROUTER_CONTAINER=sharegrid-router
HOST_CONTAINER=sharegrid-host
USER_CONTAINER=sharegrid-user
MODEL_FILE="sharegrid-host/models/Phi-3.5-mini-instruct-IQ2_M.gguf"

BUILD=1
SERVER_MODE=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --server)   SERVER_MODE=1 ;;
    *) echo "[start-dev] WARNING: unknown flag: $arg" ;;
  esac
done

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
docker rm -f "$USER_CONTAINER"   2>/dev/null || true

# Also evict any other containers that happen to be occupying the same ports.
log "Checking for port conflicts..."
clear_port "$ROUTER_PORT"
clear_port "$HOST_PORT"
if [[ "$SERVER_MODE" -eq 1 ]]; then
  clear_port "$USER_SERVER_PORT"
fi

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

# Detect host IPs to pass into the router container.
# The container only sees its Docker bridge interface, so LAN and public IPv6
# addresses must be resolved on the host and injected as env vars.
log "Detecting host network addresses..."
PRIMARY_IFACE=$(route get default 2>/dev/null | awk '/interface:/{print $2}')
SHAREGRID_LAN_IPS=$(ipconfig getifaddr "$PRIMARY_IFACE" 2>/dev/null || true)
SHAREGRID_PUBLIC_IPV6=$(curl -6 --max-time 3 -s https://api6.ipify.org 2>/dev/null || true)
[[ -n "$SHAREGRID_LAN_IPS" ]]     && log "LAN IP: ${SHAREGRID_LAN_IPS}"     || log "LAN IP: not detected"
[[ -n "$SHAREGRID_PUBLIC_IPV6" ]] && log "Public IPv6: ${SHAREGRID_PUBLIC_IPV6}" || log "Public IPv6: not detected"

log "Starting sharegrid-router..."
docker run -d \
  --name "$ROUTER_CONTAINER" \
  --network "$NETWORK" \
  -p "${ROUTER_PORT}:${ROUTER_PORT}" \
  -e SHAREGRID_LISTEN_ADDR=":::${ROUTER_PORT}" \
  -e SHAREGRID_LAN_IPS="$SHAREGRID_LAN_IPS" \
  -e SHAREGRID_PUBLIC_IPV6="$SHAREGRID_PUBLIC_IPV6" \
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

log "Host registered."

# ── Step 7: Start user ────────────────────────────────────────────────────────

if [[ "$SERVER_MODE" -eq 1 ]]; then
  # ── Server mode: background HTTP adapter for OpenCode ─────────────────────

  log "Starting sharegrid-user in server mode on port ${USER_SERVER_PORT}..."
  docker run -d \
    --name "$USER_CONTAINER" \
    --network "$NETWORK" \
    -p "${USER_SERVER_PORT}:${USER_SERVER_PORT}" \
    -e SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
    -e SHAREGRID_MODE=server \
    -e SHAREGRID_LISTEN_HOST=0.0.0.0 \
    sharegrid-user

  log "Provider adapter running on http://localhost:${USER_SERVER_PORT}/v1"
  log ""
  log "Add to your opencode.json:"
  echo ""
  cat <<EOF
{
  "provider": {
    "sharegrid": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "ShareGrid",
      "options": { "baseURL": "http://localhost:${USER_SERVER_PORT}/v1" }
    }
  }
}
EOF
  echo ""
  log "Router, host, and user adapter are all running in the background."
  log "Stop all: docker rm -f ${ROUTER_CONTAINER} ${HOST_CONTAINER} ${USER_CONTAINER}"

else
  # ── CLI mode: interactive foreground session ──────────────────────────────

  log "Launching sharegrid-user (CLI mode)..."
  exec docker run -it --rm \
    --network "$NETWORK" \
    -e SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
    -e SHAREGRID_MODE=cli \
    sharegrid-user
fi
