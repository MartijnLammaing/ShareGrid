# Phase 5 — Dynamic OpenCode Model Sync

> **Scope:** Phase 5 — automatically synchronise the `sharegrid` provider block in
> `~/.config/opencode/opencode.jsonc` with the models that are live on the ShareGrid
> network, removing this manual step from the operator workflow.
>
> **Prerequisite:** Phase 4 fully merged to `main`.

---

## How to use this document

1. Tasks are grouped into sub-phases. Each task is intentionally small: one file,
   one clear contract, one verifiable outcome.
2. Each task has a **Status** field. Update it when the task is complete.
3. Complete sub-phases in order.

### Status legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete |
| `[!]` | Blocked — see notes |

---

## Background

The `opencode.jsonc` config currently hardcodes the model names and context limits
for the `sharegrid` provider. When a host registers with a different model the config
must be updated by hand.

`sharegrid-user` already exposes a `GET /v1/models` endpoint that returns the live
model list from the router, including each model's `context_length`. Phase 5 adds a
script that calls this endpoint and writes the correct `models` block into
`opencode.jsonc`, replacing stale entries and adding new ones. The script is called
automatically when `docker-run.sh` starts the server.

---

## Design decisions

**`jq` + `curl` over Node.js**
Both are available on macOS without extra installation (`/usr/bin/jq`,
`/usr/bin/curl`). A pure-bash script keeps the toolchain dependency-free and works
both inside and outside a Node project.

**JSONC comment caveat**
`jq` parses standard JSON only; it does not preserve JSONC comments. If the user has
added comments to `opencode.jsonc` they will be stripped on the first run. This is
documented in the script's header. The `$schema` field and all structured data are
preserved.

**Selective update — only `sharegrid.models` is touched**
If a `sharegrid` provider already exists, only its `models` block is replaced. Custom
`baseURL`, `npm`, `name`, and `options` fields are left intact. If no `sharegrid`
provider exists, the full default block is inserted. All other providers are
completely untouched.

**Stale model cleanup is automatic**
The `models` block is replaced wholesale with the live API response. Any model that
is no longer registered on the network is removed. No separate cleanup step is needed.

**`context_length` → `limit.context`; `output` fixed at 4096**
The `/v1/models` endpoint returns `context_length` per model (sourced from the host's
`SHAREGRID_MODEL_CONTEXT_SIZE`). This is used directly for `limit.context`. The API
does not expose a separate output limit; `limit.output` is hardcoded to `4096` (the
existing convention in the config).

**Retry loop**
The server needs a moment to start and to fetch the host list from the router. The
script retries the `/v1/models` call up to 15 times with a 2-second pause between
attempts before giving up.

**Port follows `SHAREGRID_USER_PORT`**
The script reads `SHAREGRID_USER_PORT` (default `3000`) so it stays consistent with
`docker-run.sh`.

---

## Phase overview

| Sub-phase | Title | Tasks | Depends on |
|-----------|-------|:-----:|------------|
| 5.0 | `refresh-opencode.sh` script | 5 | Phase 4 merged |
| 5.1 | `docker-run.sh` integration | 2 | Sub-phase 5.0 done |
| 5.2 | Manual verification | 4 | Sub-phase 5.1 done |

---

## Sub-phase 5.0 — `refresh-opencode.sh`

Create `sharegrid-user/refresh-opencode.sh`. The script is self-contained and can be
run manually at any time as well as being called from `docker-run.sh`.

### Inputs (environment variables, all optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `SHAREGRID_USER_PORT` | `3000` | Port the sharegrid-user server is listening on |
| `OPENCODE_CONFIG` | `~/.config/opencode/opencode.jsonc` | Path to the opencode config file |

### Behaviour

1. Derive `BASE_URL=http://localhost:${SHAREGRID_USER_PORT}/v1`.
2. Retry `GET ${BASE_URL}/models` up to 15 times, 2 s apart. Exit with an error if
   all attempts fail.
3. Abort with a warning (exit 0, non-fatal) if the response contains zero models —
   do not write an empty `models` block.
4. Build a `models` JSON object from the response:
   - key = `model.id`
   - value = `{ "name": "<id>", "limit": { "context": <context_length>, "output": 4096 } }`
5. If `OPENCODE_CONFIG` does not exist, create the parent directory and write a
   minimal valid file: `{ "$schema": "https://opencode.ai/config.json", "provider": {} }`.
6. Read the config with `jq`:
   - If `.provider.sharegrid` already exists → replace only `.provider.sharegrid.models`.
   - If `.provider.sharegrid` is absent → insert the full default block:
     ```json
     {
       "npm": "@ai-sdk/openai-compatible",
       "name": "ShareGrid",
       "options": { "baseURL": "http://localhost:3000/v1" },
       "models": { … }
     }
     ```
7. Write to a `.tmp` file then atomically `mv` it over the original (prevents a
   partial write from corrupting the config).
8. Print a summary: number of models written, config path.

| # | Task | File | Status |
|---|------|------|:------:|
| P5-1 | Create `sharegrid-user/refresh-opencode.sh` with the header comment, `set -euo pipefail`, and env-var defaults (`PORT`, `CONFIG_PATH`). Make it executable (`chmod +x`). | `sharegrid-user/refresh-opencode.sh` | `[ ]` |
| P5-2 | Implement the retry loop: `curl -sf` with a 5 s timeout, 15 attempts, 2 s sleep. Print attempt number on each retry. Exit 1 if all attempts are exhausted. | `sharegrid-user/refresh-opencode.sh` | `[ ]` |
| P5-3 | Implement the `jq` pipeline that converts the API response to the `models` object, and abort (exit 0 + warning) if the model count is zero. | `sharegrid-user/refresh-opencode.sh` | `[ ]` |
| P5-4 | Implement config read/create and the `jq` merge: create the file if absent; replace only `.provider.sharegrid.models` if the provider exists; insert the full default block if it is absent. Write via `.tmp` + `mv`. | `sharegrid-user/refresh-opencode.sh` | `[ ]` |
| P5-5 | Add the summary log line and verify the script runs cleanly in isolation against a running `sharegrid-user` server. | `sharegrid-user/refresh-opencode.sh` | `[ ]` |

---

## Sub-phase 5.1 — `docker-run.sh` integration

Call `refresh-opencode.sh` automatically after the server container starts in
`--server` mode. The retry loop inside the script handles the timing — `docker-run.sh`
does not need its own wait logic.

| # | Task | File | Status |
|---|------|------|:------:|
| P5-6 | After the `docker run -d` call in `--server` mode, add a call to `"$SCRIPT_DIR/refresh-opencode.sh"`. Pass `SHAREGRID_USER_PORT` via env so the script uses the same port value. Add a log line before the call so the operator knows what is happening. | `sharegrid-user/docker-run.sh` | `[ ]` |
| P5-7 | Confirm the existing `--no-build` and `--server` flag handling is unaffected; the refresh call must only happen in server mode, not in CLI mode. | `sharegrid-user/docker-run.sh` | `[ ]` |

---

## Sub-phase 5.2 — Manual verification

| # | Check | Expected outcome | Status |
|---|-------|-----------------|:------:|
| V5-1 | Run `./docker-run.sh --server` with at least one host registered. | `opencode.jsonc` is updated with the correct model(s); context limit matches `SHAREGRID_MODEL_CONTEXT_SIZE` on the host; no other providers are modified. | `[ ]` |
| V5-2 | Run `./refresh-opencode.sh` manually while the server is running with a different set of models than what is currently in the config. | Stale models are removed; new models are added; all other providers are unchanged. | `[ ]` |
| V5-3 | Run `./refresh-opencode.sh` when `opencode.jsonc` does not exist. | File is created with `$schema` + the `sharegrid` provider block; no error. | `[ ]` |
| V5-4 | Run `./refresh-opencode.sh` when `opencode.jsonc` exists but has no `sharegrid` provider. | The full default `sharegrid` block is inserted; existing providers are preserved. | `[ ]` |
