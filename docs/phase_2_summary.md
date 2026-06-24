# Phase 2 — OpenCode Provider Integration Completion Summary

> **Status: Complete.** 45 planned tasks across `sharegrid-shared`, LLMHost, and LLMUser are shipped and merged to `main`.

> **For agents:** The archived implementation plans linked at the [bottom of this file](#archived-implementation-plans)
> are historical task-level build records. **Do not open them during normal operation** — they contain no
> actionable information for future phases. Consult them only if explicitly instructed to investigate
> Phase 2 build history.

---

## Overview

Phase 2 transforms ShareGrid from a CLI-only chat tool into an OpenCode-compatible LLM provider. The LLMUser
is redesigned as a dual-mode service (HTTP API server + optional CLI), the LLMHost becomes a transparent
inference tunnel, and the shared protocol is updated to carry raw OpenAI request/response payloads.

All Phase 2 work lives across three repositories plus the parent mono-repo:

| Repository | Role |
|---|---|
| `sharegrid-shared` | Protocol update: Phase 1 prompt/response types replaced with `InferenceRequestPayload` / `InferenceResponseChunk` |
| `sharegrid-host` | Inference Proxy rewritten as raw OpenAI pass-through; Session Manager handles multi-turn inference loop |
| `sharegrid-user` | Redesigned as dual-mode service: HTTP API server (default) + CLI; new Host Session Pool, Model Registry, API Server |
| `ShareGrid` (parent) | `start-dev.sh` updated with `--server` flag for server-mode development |

---

## Shared Library — `sharegrid-shared`

Protocol update shared between LLMHost and LLMUser (3 tasks, driven from the LLMHost plan Phase 0).

**Wire protocol (`src/protocol.ts`)**
- Removed Phase 1 user↔host types: `ChatMessage`, `PromptPayload`, `ResponseChunk`, `ResponseEnd`, `PromptCancel`, `PromptCancelled`
- Added `InferenceRequestPayload` (`type: 'inference_request'`, `body: string`) — JSON-serialised OpenAI `/v1/chat/completions` request body
- Added `InferenceResponseChunk` (`type: 'inference_response_chunk'`, `data: string`) — one raw SSE line from llama.cpp (e.g. `"data: {...}"` or `"data: [DONE]"`)
- Updated `HostIncomingMessage` and `UserFromHostMessage` discriminated unions accordingly
- `PROTOCOL_VERSION` remains `1` — no version bump needed (router protocol unchanged)

**Tests** — new protocol type validation tests added; submodule pointers updated in `sharegrid-host`, `sharegrid-router`, `sharegrid-user`.

---

## LLMHost

A Node.js process running alongside llama.cpp inside a hardened Docker container. 15 tasks total.

**Inference Proxy rewrite (`src/inference-proxy.ts`)**
- Removed `sendPrompt()` / `cancelPrompt()` — replaced with `forwardInference(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal): Promise<void>`
- POSTs `body` verbatim to `http://unix:/tmp/llama.sock:/v1/chat/completions` — no content parsing, no text extraction
- Streams SSE lines back via `onChunk`; detects `data: [DONE]` to resolve
- On `signal` abort: destroys the in-flight request, then calls `flushSlot()` to erase the KV cache

**Session Manager rewrite (`src/session-manager.ts`)**
- Replaced single-prompt message loop with a multi-turn inference loop: wait for `inference_request` → forward → stream SSE → loop back
- Socket teardown mid-inference: `'close'` / `'error'` → `AbortController.abort()` → `flushSlot()` → `process.exit(1)` if flush fails
- Idle timer resets on each `inference_request` (not per prompt); default 30 minutes
- `session_close` exits the loop and tears down; unknown message types are logged and ignored

**Router Client & llama-server launcher** — unchanged from Phase 1.

**Tests** — 120 unit tests + 5 integration tests (happy path, slot busy, slot erase failure, slot release, multi-turn).

---

## LLMUser

A Node.js process running inside a Docker container (or directly on the user's machine). 27 tasks total.

**Config (`src/config.ts`)**
- Added `SHAREGRID_LISTEN_PORT` (integer, 1–65535, default `3000`)
- Added `SHAREGRID_MODE` (enum `'server' | 'cli'`, default `'server'`)
- `SHAREGRID_ROUTER_URL` validation unchanged

**Session Client (`src/session-client.ts`)**
- Replaced Phase 1 text-based protocol with `sendInferenceRequest(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal): Promise<void>`
- Sends `inference_request`, collects `inference_response_chunk` messages, calls `onChunk` for each `data` field
- Resolves on `data: [DONE]`; `abort()` destroys socket immediately (host detects close and flushes KV cache)
- `isAlive(): boolean` for liveness detection by the Host Session Pool

**Host Session Pool (`src/host-session-pool.ts`)**
- `Map<string, SessionClient>` keyed by `hostId`; `acquire(host)` returns existing live session or opens a new one
- Dead sessions are replaced on next `acquire`; `closeAll()` for graceful shutdown

**Model Registry (`src/model-registry.ts`)**
- `getModels()` calls `RouterClient.fetchHostList()`, maps to OpenAI model format (`{ id, object: 'model', owned_by: 'sharegrid' }`)
- 30-second cache (configurable TTL); `resolveHost(modelId)` finds first matching `HostListEntry`

**API Server (`src/api-server.ts`)**
- Node.js built-in `node:http` — no framework dependency
- `GET /v1/models`: returns model list from Model Registry (503 if router unreachable)
- `POST /v1/chat/completions`: parse body → force `stream: true` → resolve host → acquire session → forward inference → stream SSE back
- Client disconnect → `AbortController.abort()` → host detects close and flushes
- Unknown paths → 404

**CLI (`src/cli.ts`)**
- Uses new protocol: constructs minimal OpenAI request body, extracts `delta.content` for stdout
- Tool-call deltas produce `[tool call]` note; Ctrl+C aborts in-flight inference or closes session

**Entry point (`src/index.ts`)**
- Server mode: starts API Server, prints `opencode.json` snippet, handles `SIGTERM`/`SIGINT`
- CLI mode: runs interactive prompt loop, calls `sessionPool.closeAll()` on exit

**Dockerfile** — `EXPOSE 3000`; default `CMD` starts in server mode; CLI via `SHAREGRID_MODE=cli`

**Tests** — 134 unit tests + 20 integration tests (7 files) all green. Lint and typecheck clean.

---

## Development Tooling — `start-dev.sh`

Two new modes for local development:

| Invocation | Mode |
|---|---|
| `./start-dev.sh` | CLI mode — `exec docker run -it` with `SHAREGRID_MODE=cli` (foreground user session) |
| `./start-dev.sh --server` | Server mode — detached container with `-p 3000:3000 -e SHAREGRID_MODE=server`; prints `opencode.json` config snippet and exits |

---

## Archived Implementation Plans

> **Agents: do not open the files linked below unless explicitly instructed.**
> They are historical task-level records of the Phase 2 build process and contain
> no actionable information for future phases. All relevant design decisions are
> captured in the architecture documents (`architecture_overview.md`,
> `architecture_llmhost.md`, `architecture_llmuser.md`).

| Component | Archived plan |
|-----------|--------------|
| LLMHost | [`archived/phase_2/implementation_plan_llmhost.md`](archived/phase_2/implementation_plan_llmhost.md) |
| LLMUser | [`archived/phase_2/implementation_plan_llmuser.md`](archived/phase_2/implementation_plan_llmuser.md) |
