# LLMUser — Phase 2 Implementation Plan

> **Scope:** Phase 2 — OpenCode provider integration. Companion to [`architecture_llmuser.md`](./architecture_llmuser.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 2 LLMUser redesign into small, agent-sized tasks.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** column. When an agent completes a task, update its status and the summary ledger at the bottom.
3. Complete phases in order — later phases assume artefacts from earlier ones.
4. The Phase 0 `sharegrid-shared` prerequisite is **shared with the LLMHost Phase 2 plan** — complete it once; do not repeat.

### Status legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete (merged to `main`, CI green) |
| `[!]` | Blocked — see notes |

---

## Phase overview

| Phase | Title | Tasks | Depends on |
|-------|-------|:-----:|------------|
| 0 | Prerequisite: `sharegrid-shared` (shared with host plan) | — | See host plan Phase 0 |
| 1 | Config update | 2 | Phase 0 |
| 2 | Session Client update | 3 | Phase 1 |
| 3 | Host Session Pool | 2 | Phase 2 |
| 4 | Model Registry | 2 | Phase 1 |
| 5 | API Server | 4 | Phases 3–4 |
| 6 | CLI update | 2 | Phases 2–4 |
| 7 | Entry point + Dockerfile | 3 | Phases 5–6 |
| 8 | start-dev.sh update | 2 | Phase 7 |
| 9 | Unit tests | 4 | Phase 7 |
| 10 | Integration tests | 3 | Phase 9 |

---

## Phase 0 — Prerequisite: `sharegrid-shared`

See **LLMHost Phase 2 plan, Phase 0** (tasks S-15, S-16, S-17). The `sharegrid-user/sharegrid-shared` submodule pointer must be updated to the commit that includes those changes before any Phase 1 work begins here.

**Status: complete.** Submodule pointer updated to commit `fbffc67`.

---

## Phase 1 — Config update

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 1-1  | Update `src/config.ts` Zod schema. Add `SHAREGRID_LISTEN_PORT` (coerced integer, 1–65535, default `3000`) and `SHAREGRID_MODE` (enum `'server' \| 'cli'`, default `'server'`). Keep `SHAREGRID_ROUTER_URL` validation unchanged. Export the updated `Config` type. On invalid input, write a structured error to `console.error` and call `process.exit(1)`. | `src/config.ts` | `[x]` |
| 1-2  | Update unit tests for `config.ts`. Cases: `SHAREGRID_LISTEN_PORT` missing → defaults to `3000`; `SHAREGRID_LISTEN_PORT` out of range → exits 1; `SHAREGRID_MODE` missing → defaults to `'server'`; `SHAREGRID_MODE` invalid value → exits 1; both new fields valid → parses correctly. | `tests/unit/config.test.ts` | `[x]` |

---

## Phase 2 — Session Client update

Replace the Phase 1 text-based session protocol with the Phase 2 inference tunnel.

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 2-1  | Rewrite `src/session-client.ts`. The client opens a TLS connection to the host (fingerprint-pinned), sends `session_open`, and handles `session_ack` / `session_reject`. Expose `sendInferenceRequest(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal): Promise<void>`: sends an `inference_request` message, reads `inference_response_chunk` messages and calls `onChunk` for each `data` field, resolves when `data: [DONE]` is received. Expose `close(): void` — sends `session_close` and destroys the socket. Expose `abort(): void` — destroys the socket immediately (used for cancellation; host detects close and flushes its KV cache). | `src/session-client.ts` | `[x]` |
| 2-2  | The Session Client must handle the case where the `signal` is aborted while waiting for chunks: destroy the socket, return. Also handle socket errors: reject the `sendInferenceRequest` promise; mark the client as dead (so the Host Session Pool can detect it). Expose `isAlive(): boolean`. | `src/session-client.ts` | `[x]` |
| 2-3  | Unit tests for Session Client. Cases: `session_open` with valid token → `session_ack` received; `sendInferenceRequest` sends correct `inference_request` JSON; `onChunk` called for each `inference_response_chunk.data`; resolves on `data: [DONE]`; `abort()` destroys socket; `signal` abort → socket destroyed; `session_reject` with reason `busy` → rejects with `HostBusyError`; `session_reject` with reason `invalid_token` → rejects with `InvalidTokenError`. | `tests/unit/session-client.test.ts` | `[x]` |

---

## Phase 3 — Host Session Pool

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 3-1  | Create `src/host-session-pool.ts`. Interface: `HostSessionPool` with `acquire(host: HostListEntry): Promise<SessionClient>` and `closeAll(): Promise<void>`. Implementation: maintain a `Map<string, SessionClient>` keyed by `hostId`. `acquire`: if a live session exists (`.isAlive() === true`), return it; otherwise open a new `SessionClient` (instantiate, open, await `session_ack`), store it, and return it. On `session_ack` rejection propagate the error. `closeAll`: call `.close()` on all sessions; clear the map. | `src/host-session-pool.ts` | `[x]` |
| 3-2  | Unit tests for Host Session Pool. Cases: first `acquire` opens a new session; second `acquire` for same `hostId` returns the existing session without re-opening; after session dies (`isAlive()` returns `false`), next `acquire` opens a fresh session; `closeAll` calls `close()` on all sessions; `acquire` on host with busy slot propagates `HostBusyError`. | `tests/unit/host-session-pool.test.ts` | `[x]` |

---

## Phase 4 — Model Registry

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 4-1  | Create `src/model-registry.ts`. Interface: `ModelRegistry` with `getModels(): Promise<OpenAIModel[]>` and `resolveHost(modelId: string): Promise<HostListEntry>`. Implementation: call `RouterClient.fetchHostList()` on each `getModels()` call; cache the result for 30 seconds (configurable via `ModelRegistryOptions.cacheTtlMs`). Map each `HostListEntry` to `{ id: entry.modelName, object: 'model', owned_by: 'sharegrid' }`. `resolveHost`: find the first `HostListEntry` whose `modelName === modelId`; throw `HostNotFoundError` if none. Define `OpenAIModel` as `{ id: string; object: 'model'; owned_by: string }` — export it for use by the API Server. | `src/model-registry.ts` | `[x]` |
| 4-2  | Unit tests for Model Registry. Cases: `getModels()` calls router and maps correctly; second call within TTL uses cache without calling router again; call after TTL expiry re-fetches; `resolveHost` returns the correct entry; `resolveHost` throws `HostNotFoundError` for unknown model. | `tests/unit/model-registry.test.ts` | `[x]` |

---

## Phase 5 — API Server

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 5-1  | Create `src/api-server.ts`. Use Node.js built-in `node:http` (`createServer`) — no framework dependency. Export `createApiServer(deps: ApiServerDeps): ApiServer` where `ApiServerDeps = { config: Config, modelRegistry: ModelRegistry, sessionPool: HostSessionPool, logger: Logger }` and `ApiServer = { start(): Promise<void>; stop(): Promise<void> }`. Bind to `127.0.0.1:config.SHAREGRID_LISTEN_PORT`. | `src/api-server.ts` | `[ ]` |
| 5-2  | Implement `GET /v1/models`: call `modelRegistry.getModels()`, return `{ object: 'list', data: [...] }` as JSON with `Content-Type: application/json`. On error (router unreachable): return HTTP 503 with a JSON error body. | `src/api-server.ts` | `[ ]` |
| 5-3  | Implement `POST /v1/chat/completions`: (a) parse JSON request body; (b) extract `model`; force `stream: true` in the body (set it if absent); (c) call `modelRegistry.resolveHost(model)` — return 404 on `HostNotFoundError`; (d) call `sessionPool.acquire(host)` — return 503 on `HostBusyError`; (e) set SSE response headers (`Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`); (f) create an `AbortController`; (g) call `session.sendInferenceRequest(body, onChunk, signal)` where `onChunk` writes each SSE line to the response; (h) on stream end, end the HTTP response; (i) on HTTP request `'close'` event (client disconnects): call `controller.abort()`; (j) on error: return 500. Unrecognised paths → 404. | `src/api-server.ts` | `[ ]` |
| 5-4  | Unit tests for API Server. Cases: `GET /v1/models` returns correct OpenAI model list shape; `GET /v1/models` returns 503 when model registry throws; `POST /v1/chat/completions` with valid model → `sendInferenceRequest` called with correct body; SSE lines are forwarded verbatim as HTTP response chunks; `data: [DONE]` ends the response; client disconnect triggers `controller.abort()`; unknown model → 404; host busy → 503; unknown path → 404. | `tests/unit/api-server.test.ts` | `[ ]` |

---

## Phase 6 — CLI update

Update the CLI to work with the new session protocol. The UX is unchanged — the CLI is still an interactive prompt/response terminal.

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 6-1  | Update `src/cli.ts` to use the new protocol. Host selection: call `modelRegistry.getModels()` and `modelRegistry.resolveHost()` to get the `HostListEntry`. Session open: call `sessionPool.acquire(host)`. Prompt loop: construct a minimal OpenAI request body `{ model: host.modelName, messages: [...], stream: true }` with no tool definitions; call `sessionClient.sendInferenceRequest(body, onChunk, signal)`. In `onChunk`: parse each raw SSE line to extract `choices[0].delta.content` and write it to `process.stdout`. If the line contains a tool-call delta (`choices[0].delta.tool_calls`), write a brief `[tool call]` note. Ctrl+C during generation: set the `AbortController` signal. Ctrl+C at prompt: call `sessionClient.close()` and exit. | `src/cli.ts` | `[ ]` |
| 6-2  | Unit tests for CLI. Cases: host list is displayed on startup; user selection resolves to the correct host; prompt input sends `inference_request` with correct messages array; `delta.content` values are written to stdout; Ctrl+C during generation calls `abort()`; Ctrl+C at prompt calls `close()` then exits. | `tests/unit/cli.test.ts` | `[ ]` |

---

## Phase 7 — Entry point + Dockerfile

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 7-1  | Rewrite `src/index.ts`. (a) Load config with `loadConfig()`. (b) Create `RouterClient`, `ModelRegistry`, `HostSessionPool`. (c) If `config.SHAREGRID_MODE === 'server'`: create `ApiServer` and start it; print the `opencode.json` snippet to stdout at startup; register `SIGTERM`/`SIGINT` handlers that call `sessionPool.closeAll()` then `apiServer.stop()`. (d) If `config.SHAREGRID_MODE === 'cli'`: run the CLI; on exit call `sessionPool.closeAll()`. | `src/index.ts` | `[ ]` |
| 7-2  | Update `Dockerfile`. Add `EXPOSE 3000` for the HTTP server port. Default `CMD` starts in server mode (`node /app/bundle.cjs`). The CLI is available by passing `SHAREGRID_MODE=cli` as an environment variable or running `docker run -it -e SHAREGRID_MODE=cli ...`. | `Dockerfile` | `[ ]` |
| 7-3  | Verify `npm run build` (esbuild) and `npm run typecheck` pass with zero errors. Verify the bundle starts cleanly in both modes. | `src/`, `Dockerfile` | `[ ]` |

---

## Phase 8 — start-dev.sh update

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 8-1  | Add `--server` flag to `start-dev.sh`. When `--server` is passed: after host registration is confirmed, start the `sharegrid-user` container detached with `-p 3000:3000 -e SHAREGRID_MODE=server -e SHAREGRID_ROUTER_URL="$USER_ROUTER_URL"` and print the `opencode.json` config snippet. The script exits after printing rather than becoming the user process. When `--server` is not passed (default): keep the existing `exec docker run -it` behaviour for CLI mode, passing `SHAREGRID_MODE=cli`. | `start-dev.sh` | `[ ]` |
| 8-2  | Update the `sharegrid-user` build step in `start-dev.sh` to include the host-side `--build-arg` equivalent for the user image if needed (the user image has no model file, so `MODEL_FILE` is not needed). Verify `./start-dev.sh --server` and `./start-dev.sh` both work end-to-end. | `start-dev.sh` | `[ ]` |

---

## Phase 9 — Unit tests

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 9-1  | Run the full unit test suite (`npm run test:unit`). Fix any regressions in existing tests caused by the session client / config changes. | All unit test files | `[ ]` |
| 9-2  | Run `npm run typecheck`. Fix any type errors. | All source files | `[ ]` |
| 9-3  | Run `npm run lint`. Fix any lint errors. | All source files | `[ ]` |
| 9-4  | Ensure all new unit tests added in Phases 1–7 pass with `npm run test:unit`. | All new `*.test.ts` files | `[ ]` |

---

## Phase 10 — Integration tests

| #    | Task | File / Location | Status |
|------|------|-----------------|:------:|
| 10-1 | Update integration test helpers (`tests/integration/helpers.ts`). Remove Phase 1 fixtures (`PromptPayload` etc.). Add a helper `sendInference(session, body)` that sends an `inference_request` and collects all `inference_response_chunk.data` lines until `data: [DONE]`. Add a `MockLlamaServer` helper that accepts HTTP connections on a Unix socket and emits configurable SSE responses (including tool-call chunks). | `tests/integration/helpers.ts` | `[ ]` |
| 10-2 | Write integration tests for the full server-mode flow. Cases: `GET /v1/models` returns models from a mock router; `POST /v1/chat/completions` opens a session, sends `inference_request`, receives SSE stream, streams it back to the HTTP client; multi-turn: second `POST` reuses the existing session; client disconnect mid-stream aborts the inference; host busy returns 503. | `tests/integration/server.test.ts` | `[ ]` |
| 10-3 | Write integration tests for CLI mode. Cases: host list is fetched and displayed; prompt → inference → text displayed; second prompt reuses session; Ctrl+C aborts in-flight inference cleanly. | `tests/integration/cli.test.ts` | `[ ]` |

---

## Status ledger

| Phase | Title | Total | Done | In progress | Blocked | Remaining |
|-------|-------|:-----:|:----:|:-----------:|:-------:|:---------:|
| 0 | `sharegrid-shared` (see host plan) | — | — | — | — | — |
| 1 | Config update | 2 | 2 | 0 | 0 | 0 |
| 2 | Session Client update | 3 | 3 | 0 | 0 | 0 |
| 3 | Host Session Pool | 2 | 2 | 0 | 0 | 0 |
| 4 | Model Registry | 2 | 2 | 0 | 0 | 0 |
| 5 | API Server | 4 | 0 | 0 | 0 | 4 |
| 6 | CLI update | 2 | 0 | 0 | 0 | 2 |
| 7 | Entry point + Dockerfile | 3 | 0 | 0 | 0 | 3 |
| 8 | start-dev.sh update | 2 | 0 | 0 | 0 | 2 |
| 9 | Unit tests | 4 | 0 | 0 | 0 | 4 |
| 10 | Integration tests | 3 | 0 | 0 | 0 | 3 |
| — | **Total** | **27** | **9** | **0** | **0** | **18** |

### Notes / blockers

- **Phases 1–4 complete.** Config schema, Session Client, Host Session Pool, and Model Registry all implemented and tested (123 unit tests green).
- **Phase 0 prerequisite satisfied.** `sharegrid-user/sharegrid-shared` updated to commit `fbffc67` (Phase 2 protocol types).
- **Phases 5–10 not started.** Natural next phases: 5 (API Server) depends on Phases 3+4, then 6 (CLI update), 7 (entry point + Dockerfile), 8 (start-dev.sh), and finally 9–10 (tests).

---

## Conventions reminder for implementers

- Source files: `kebab-case.ts`. Functions/variables: `camelCase`. (See `implementation_guidelines.md` §3.)
- Named exports only. No default exports.
- `async`/`await` only. No raw `.then()` chains.
- No framework dependencies for the HTTP server — use Node.js built-in `node:http` only.
- No `TODO` comments merged to `main` — open an issue instead.
- Conventional Commits with scope `user`: e.g. `feat(user): add openai-compatible api server`.
- One PR per task or per tightly related task cluster. CI must be green before merge.
