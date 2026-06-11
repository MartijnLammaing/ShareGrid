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

BUILD=1
SERVER_MODE=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --server)   SERVER_MODE=1 ;;
    *) echo "[start-dev] WARNING: unknown flag: $arg" ;;
  esac
done

BUILD_FLAG=""
if [[ "$BUILD" -eq 0 ]]; then
  BUILD_FLAG="--no-build"
fi

SERVER_FLAG=""
if [[ "$SERVER_MODE" -eq 1 ]]; then
  SERVER_FLAG="--server"
fi

log() { echo "[start-dev] $*"; }

# ── Step 1: Cleanup ───────────────────────────────────────────────────────────

log "Removing existing named containers (if any)..."
docker rm -f sharegrid-router 2>/dev/null || true
docker rm -f sharegrid-host   2>/dev/null || true
docker rm -f sharegrid-user   2>/dev/null || true

# ── Step 2: Start router ──────────────────────────────────────────────────────

log "Starting sharegrid-router..."
ROUTER_OUTPUT=$("$SCRIPT_DIR/sharegrid-router/docker-run.sh" $BUILD_FLAG)

HOST_ROUTER_URL=$(echo "$ROUTER_OUTPUT" | grep 'SHAREGRID_HOST_ROUTER_URL=' | cut -d= -f2-)
USER_ROUTER_URL=$(echo "$ROUTER_OUTPUT" | grep 'SHAREGRID_USER_ROUTER_URL=' | cut -d= -f2-)

if [[ -z "$HOST_ROUTER_URL" || -z "$USER_ROUTER_URL" ]]; then
  log "ERROR: Failed to extract URLs from router output."
  echo "$ROUTER_OUTPUT"
  exit 1
fi

log "Host registration URL: ${HOST_ROUTER_URL}"
log "User access URL:       ${USER_ROUTER_URL}"

# ── Step 3: Start host ────────────────────────────────────────────────────────

log "Starting sharegrid-host..."
SHAREGRID_ROUTER_URL="$HOST_ROUTER_URL" \
  "$SCRIPT_DIR/sharegrid-host/docker-run.sh" $BUILD_FLAG

# ── Step 4: Start user ────────────────────────────────────────────────────────

if [[ "$SERVER_MODE" -eq 1 ]]; then
  log "Starting sharegrid-user (server mode)..."
  SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
    "$SCRIPT_DIR/sharegrid-user/docker-run.sh" $BUILD_FLAG --server

  log ""
  log "Router, host, and user adapter are all running in the background."
  log "Stop all: docker rm -f sharegrid-router sharegrid-host sharegrid-user"
else
  log "Launching sharegrid-user (CLI mode)..."
  export SHAREGRID_ROUTER_URL="$USER_ROUTER_URL"
  exec "$SCRIPT_DIR/sharegrid-user/docker-run.sh" $BUILD_FLAG
fi
