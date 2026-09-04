# BG-3 — Interactive user launcher

Backlog item: add a script that runs the user executable as a script, asking for specific parameters instead of requiring them at command run.

## Goal

Create `sharegrid-user/run-user.sh`, an interactive wrapper around the existing `sharegrid-user/docker-run.sh`.

## Constraints

- The user still runs inside Docker via `docker-run.sh`.
- Only prompt for user-facing parameters.
- Place the new script alongside `docker-run.sh`.
- Do not modify `docker-run.sh`.

## Prompts and defaults

| Parameter | Prompt text | Default |
|-----------|-------------|---------|
| Router URL | `Paste the USER ACCESS URL from the router banner (base64 token)` | `${SHAREGRID_ROUTER_URL:-}` |
| Mode | `Mode (cli/server)` | `${SHAREGRID_MODE:-cli}` |
| Port | `Host port to publish (server mode only)` | `${SHAREGRID_USER_PORT:-3000}` |
| Docker image | `Docker image name` | `${SHAREGRID_USER_IMAGE:-sharegrid-user}` |
| Build image | `Build Docker image before starting? [Y/n]` | `yes` |

Notes:
- The router URL is the **base64 token** printed by `sharegrid-router/docker-run.sh` as `SHAREGRID_USER_ROUTER_URL=...`. The existing `docker-run.sh` decodes it automatically.
- Port is only asked when mode is `server`; it is ignored in `cli` mode.
- Default mode is `cli` to match `docker-run.sh`.

## Validation

- Router URL must be non-empty.
- Mode must be exactly `cli` or `server`.
- Port must be an integer between 1 and 65535.
- Docker image name must be non-empty.

## Invocation

Export the collected answers into the corresponding environment variables and call:

```bash
export SHAREGRID_ROUTER_URL="$ROUTER_URL"
export SHAREGRID_USER_PORT="$PORT"
export SHAREGRID_USER_IMAGE="$IMAGE"

SERVER_FLAG=""
if [[ "$MODE" == "server" ]]; then
  SERVER_FLAG="--server"
fi

BUILD_FLAG=""
case "$BUILD_ANSWER_LOWER" in
  y|yes) BUILD_FLAG="" ;;
  n|no)  BUILD_FLAG="--no-build" ;;
esac

exec "$SCRIPT_DIR/docker-run.sh" ${BUILD_FLAG:-} ${SERVER_FLAG:-}
```

## Non-interactive fallback

Support a `--no-prompt` flag (or skip prompts when stdin is not a TTY) so that scripts and CI can use the wrapper purely via environment variables. Also support `--no-build` to skip the Docker build step.

## Testing

1. Run `shellcheck sharegrid-user/run-user.sh`.
2. Verify `./run-user.sh --no-prompt --no-build` matches the behavior of calling `./docker-run.sh --no-build` with the same env vars.
3. Test interactive prompts with piped input.
4. Test validation error paths (empty URL, invalid mode, invalid port).
5. Run `start-dev.sh` to confirm no regression in `docker-run.sh`.

## Completion

- Make `sharegrid-user/run-user.sh` executable.
- `docs/backlog.md` did not contain a separate user-launcher item, so no backlog update was required.
