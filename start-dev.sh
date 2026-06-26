#!/usr/bin/env bash
# start-dev.sh — Start the full ShareGrid network stack on a single machine.
#
# Modules connect over the LAN using IPv4 (the default ShareGrid network model):
# each docker-run.sh auto-detects this machine's LAN IPv4 and the router, host,
# and user reach each other via that address and their published ports. There is
# no shared Docker bridge — running all three here simply exercises the same LAN
# path that separate machines would use.
#
# Internet mode (IPv6): set SHAREGRID_NETWORK_MODE=internet to advertise
# globally-routable IPv6 addresses instead. The router docker-run.sh inherits
# SHAREGRID_NETWORK_MODE; the host docker-run.sh derives its mode from the
# mode=internet query parameter embedded in the router URL. Both scripts accept
# the optional SHAREGRID_ADVERTISE_IP override. Note that internet mode requires
# Docker IPv6 support and is intended for cross-machine deployment rather than
# single-host dev.
#
# Usage: ./start-dev.sh [--no-build] [--server] [--macos-host]
#   SHAREGRID_NETWORK_MODE=internet ./start-dev.sh   # advertise IPv6
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
# --macos-host:
#   Run sharegrid-host natively on macOS using macos-native/macos-run.sh instead
#   of the Docker container. The router and user are still started via Docker.
#   Useful for testing the Metal / sandbox-exec path on Apple Silicon.
#
# Flags can appear in any order and are independent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD=1
SERVER_MODE=0
MACOS_HOST=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --server)   SERVER_MODE=1 ;;
    --macos-host) MACOS_HOST=1 ;;
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

# Stop the native macOS host and all of its children. The wrapper script, the
# `while … node …` restart loop, the Node host process, and the llama-server
# child must all be terminated — killing only the wrapper PID leaves the restart
# loop running, which would immediately respawn the host.
stop_native_host() {
  pkill -f "sharegrid-host/macos-native/macos-run.sh" 2>/dev/null || true
  pkill -f "sharegrid-host/dist/bundle.cjs" 2>/dev/null || true
  pkill -f "llama-server" 2>/dev/null || true
  sleep 1
  for pid in $(lsof -ti:"${SHAREGRID_HOST_PORT:-9000}" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
  done
  for pid in $(lsof -t /tmp/llama.sock 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
  done
  rm -f /tmp/llama.sock
}

# ── Step 1: Cleanup ───────────────────────────────────────────────────────────

log "Removing existing named containers (if any)..."
docker rm -f sharegrid-router 2>/dev/null || true
docker rm -f sharegrid-host   2>/dev/null || true
docker rm -f sharegrid-user   2>/dev/null || true

# Stop a previously running native macOS host, if any, so the next run can bind
# to SHAREGRID_HOST_PORT (default 9000) and the fixed Unix socket at
# /tmp/llama.sock.
if [[ "$MACOS_HOST" -eq 1 ]]; then
  stop_native_host
  for i in $(seq 1 30); do
    if ! lsof -ti:"${SHAREGRID_HOST_PORT:-9000}" >/dev/null 2>&1 && \
       ! lsof -t /tmp/llama.sock >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
fi

# Remove the obsolete shared bridge network from pre-LAN setups, if present.
docker network rm sharegrid-net 2>/dev/null || true

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

if [[ "$MACOS_HOST" -eq 1 ]]; then
  log "Starting sharegrid-host natively (macos-run.sh)..."
  # Capture the host output to a log file so we can wait for registration before
  # starting the user (the native path is slow to start: it loads the model and
  # warms up llama.cpp). Stream the log to this terminal until the host is ready.
  HOST_LOG="$(mktemp -t sharegrid-host.XXXXXX)"
  SHAREGRID_ROUTER_URL="$HOST_ROUTER_URL" \
    "$SCRIPT_DIR/sharegrid-host/macos-native/macos-run.sh" >"$HOST_LOG" 2>&1 &
  HOST_PID=$!
  log "Native host PID: $HOST_PID (logging to $HOST_LOG)"
  tail -f "$HOST_LOG" & TAIL_PID=$!

  log "Waiting for host to register with router..."
  registered=0
  for i in $(seq 1 180); do
    if grep -q '"registered with router"' "$HOST_LOG" 2>/dev/null; then
      registered=1
      break
    fi
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  # Stop streaming the host log; the user output takes over the terminal next.
  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true

  if [[ "$registered" -ne 1 ]]; then
    log "ERROR: Native host did not register with the router. See $HOST_LOG"
    stop_native_host
    exit 1
  fi
  log "Host registered."
else
  log "Starting sharegrid-host (Docker)..."
  SHAREGRID_ROUTER_URL="$HOST_ROUTER_URL" \
    "$SCRIPT_DIR/sharegrid-host/docker-run.sh" $BUILD_FLAG
fi

# ── Step 4: Start user ────────────────────────────────────────────────────────

if [[ "$SERVER_MODE" -eq 1 ]]; then
  log "Starting sharegrid-user (server mode)..."
  SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
    "$SCRIPT_DIR/sharegrid-user/docker-run.sh" $BUILD_FLAG --server

  log ""
  if [[ "$MACOS_HOST" -eq 1 ]]; then
    log "Router and user adapter are running in Docker; host is running natively."
    log "Host log: $HOST_LOG"
    log "Stop host: sharegrid-host/macos-native/ processes (pkill -f macos-run.sh; pkill -f llama-server)"
    log "Stop containers: docker rm -f sharegrid-router sharegrid-user"
  else
    log "Router, host, and user adapter are all running in the background."
    log "Stop all: docker rm -f sharegrid-router sharegrid-host sharegrid-user"
  fi
  else
    if [[ "$MACOS_HOST" -eq 1 ]]; then
      # Run the CLI container interactively in the foreground. The host wrapper
      # was backgrounded above, so it stays alive while the user interacts.
      log "Starting sharegrid-user (CLI mode)..."
      if [[ "$BUILD" -eq 1 ]]; then
        log "Building sharegrid-user image..."
        docker build -t sharegrid-user "$SCRIPT_DIR/sharegrid-user"
      fi
      export SHAREGRID_ROUTER_URL="$USER_ROUTER_URL"
      # Ensure the native host (and its restart loop + llama-server) is torn down
      # when the user exits the CLI.
      trap 'log "Stopping native host..."; stop_native_host' EXIT
      exec docker run -it --rm --name sharegrid-user \
        -e SHAREGRID_ROUTER_URL="$USER_ROUTER_URL" \
        -e SHAREGRID_MODE=cli \
        sharegrid-user:latest
    else
    log "Launching sharegrid-user (CLI mode)..."
    export SHAREGRID_ROUTER_URL="$USER_ROUTER_URL"
    exec "$SCRIPT_DIR/sharegrid-user/docker-run.sh" $BUILD_FLAG
  fi
fi
