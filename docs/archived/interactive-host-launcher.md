# BG-2 — Interactive host launcher

Goal: add a script that runs the host executable as a script, asking for specific parameters instead of requiring them at command run.

## Scope

Create `sharegrid-host/run-host.sh`, an interactive wrapper around either:

- `sharegrid-host/docker-run.sh` (Docker deployment, all platforms)
- `sharegrid-host/macos-native/macos-run.sh` (native Apple Silicon macOS deployment)

## Constraints

- The host still runs via `docker-run.sh` or `macos-run.sh`.
- Only prompt for user-facing parameters.
- Place the new script alongside `docker-run.sh`.
- Do not modify `docker-run.sh` or `macos-run.sh`.

## Prompts and defaults

### Common prompts

| Parameter | Prompt text | Default |
|-----------|-------------|---------|
| Router URL | `Paste HOST REGISTRATION URL from the router banner (base64 token)` | `${SHAREGRID_ROUTER_URL:-}` |
| Port | `Host port to publish` | `${SHAREGRID_HOST_PORT:-9000}` |
| Advertise IP | `Advertise IP (empty = auto-detect)` | `${SHAREGRID_ADVERTISE_IP:-<auto-detected from router mode>}` |

### macOS-only deployment target prompt

On Apple Silicon macOS, also ask:

| Parameter | Prompt text | Default |
|-----------|-------------|---------|
| Deployment target | `Deployment target (docker/macos-native)` | `${SHAREGRID_HOST_TARGET:-docker}` |

On non-macOS or non-arm64 systems, skip this prompt and default to `docker`.

### Docker-specific prompts

Ask only when target is `docker`:

| Parameter | Prompt text | Default |
|-----------|-------------|---------|
| Docker image | `Docker image name` | `${SHAREGRID_HOST_IMAGE:-sharegrid-host}` |
| Build image | `Build Docker image before starting? [Y/n]` | `yes` |

### macOS-native-specific prompts

Ask only when target is `macos-native`:

| Parameter | Prompt text | Default |
|-----------|-------------|---------|
| Models directory | `Directory containing .gguf models` | `${SHAREGRID_MODELS_DIR:-<script-dir>/../models}` |
| llama-server binary | `Path to llama-server binary` | `${SHAREGRID_LLAMA_BINARY:-<script-dir>/bin/llama-server}` |
| Sandbox profile | `Path to sandbox-exec profile` | `${SHAREGRID_SANDBOX_PROFILE:-<script-dir>/sandbox.sb}` |

## Mode detection and advertise IP default

1. Prompt for the base64 router URL.
2. Decode it with `openssl base64 -A -d`.
3. Derive mode: `internet` if the decoded URL contains `mode=internet`, otherwise `lan`.
4. If `SHAREGRID_ADVERTISE_IP` is not already set, auto-detect:
   - `lan` → LAN IPv4
   - `internet` → globally-routable IPv6
5. Use the detected address as the default in the advertise-IP prompt.

## Validation

- Router URL must be non-empty.
- Port must be an integer between 1 and 65535.
- On macOS, deployment target must be `docker` or `macos-native`.
- Docker image name must be non-empty (Docker mode).
- Models directory must be non-empty (macOS mode).

## Non-interactive fallback

Support:

- `--no-prompt` — skip questions and use env vars/defaults.
- `--no-build` — in Docker mode, skip the Docker build step. Ignored in macOS mode.

When `--no-prompt` is used, deployment target is read from `${SHAREGRID_HOST_TARGET:-docker}`.

## Docker delegation

Export:

```bash
export SHAREGRID_ROUTER_URL="$ROUTER_URL"
export SHAREGRID_HOST_PORT="$PORT"
export SHAREGRID_HOST_IMAGE="$IMAGE"
export SHAREGRID_ADVERTISE_IP="$ADVERTISE_IP"
```

Then call:

```bash
exec "$SCRIPT_DIR/docker-run.sh" $([ "$BUILD" == "n" ] && echo "--no-build")
```

## macOS native delegation

Export:

```bash
export SHAREGRID_ROUTER_URL="$ROUTER_URL"
export SHAREGRID_HOST_PORT="$PORT"
export SHAREGRID_ADVERTISE_IP="$ADVERTISE_IP"
export SHAREGRID_MODELS_DIR="$MODELS_DIR"
export SHAREGRID_LLAMA_BINARY="$LLAMA_BINARY"
export SHAREGRID_SANDBOX_PROFILE="$SANDBOX_PROFILE"
```

Then call:

```bash
exec "$SCRIPT_DIR/macos-native/macos-run.sh"
```

## Testing

1. `bash -n sharegrid-host/run-host.sh`
2. `shellcheck sharegrid-host/run-host.sh` (if available)
3. `--no-prompt --no-build` in Docker mode → verify it delegates to `docker-run.sh --no-build`.
4. Missing router URL → clear error.
5. Invalid port / mode / target → clear errors.
6. On macOS, `--no-prompt` with `SHAREGRID_HOST_TARGET=macos-native` → verify it delegates to `macos-native/macos-run.sh`.

## Completion

- Make `sharegrid-host/run-host.sh` executable.
- Update `docs/backlog.md` to remove or mark the relevant host-launcher item.
