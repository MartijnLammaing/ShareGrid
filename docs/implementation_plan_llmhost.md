# LLMHost — Phase 2 Implementation Plan

> **Scope:** Phase 2 — OpenCode provider integration. Companion to [`architecture_llmhost.md`](./architecture_llmhost.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 2 LLMHost changes into small, agent-sized tasks.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** column. When an agent completes a task, update its status and the summary ledger at the bottom.
3. Complete phases in order — later phases assume artefacts from earlier ones.

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
| 0 | Prerequisite: `sharegrid-shared` protocol update | 3 | — |
| 1 | Inference Proxy rewrite | 3 | Phase 0 |
| 2 | Session Manager rewrite | 4 | Phase 1 |
| 3 | Unit tests | 3 | Phase 2 |
| 4 | Integration tests | 2 | Phase 3 |

---

## Phase 0 — Prerequisite: `sharegrid-shared` protocol update

These tasks update the shared protocol package. All three copies (`sharegrid-host/sharegrid-shared`, `sharegrid-router/sharegrid-shared`, `sharegrid-user/sharegrid-shared`) point to the same repository — changes must be made once and the submodule pointer updated in each consumer.

| #   | Task | File / Location | Status |
|-----|------|-----------------|:------:|
| S-15 | Remove `ChatMessage`, `PromptPayload`, `ResponseChunk`, `ResponseEnd`, `PromptCancel`, `PromptCancelled` from `src/protocol.ts`. Update the `HostIncomingMessage` and `UserFromHostMessage` discriminated union types accordingly. These types have no live consumers (Phase 1 CLI is being replaced) so removal is a clean break. | `sharegrid-shared/src/protocol.ts` | `[x]` |
| S-16 | Add two new User↔Host session message types to `src/protocol.ts`: `InferenceRequestPayload` (`type: 'inference_request'`, field `body: string` — the JSON-serialised OpenAI `/v1/chat/completions` request body) and `InferenceResponseChunk` (`type: 'inference_response_chunk'`, field `data: string` — one raw SSE line from llama.cpp, e.g. `"data: {...}"` or `"data: [DONE]"`). Both include `v: ProtocolVersion`. Update `HostIncomingMessage` and `UserFromHostMessage` union types to include the new types. | `sharegrid-shared/src/protocol.ts` | `[x]` |
| S-17 | Update unit tests: remove test cases that reference deleted types; add test cases asserting that `InferenceRequestPayload` and `InferenceResponseChunk` are valid members of their respective union types. Update the three submodule pointers in `sharegrid-host`, `sharegrid-router`, and `sharegrid-user`. | `sharegrid-shared/tests/unit/protocol.test.ts` (create if absent) | `[x]` |

---

## Phase 1 — Inference Proxy rewrite

Replace the Phase 1 text-extraction proxy with a raw pass-through. The proxy forwards the full OpenAI request body to llama.cpp and streams raw SSE lines back — no content parsing.

| #   | Task | File / Location | Status |
|-----|------|-----------------|:------:|
| 1-1 | Remove `sendPrompt()` and `cancelPrompt()` from `InferenceProxy` interface and implementation. Add `forwardInference(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal): Promise<void>`. Implementation: POST `body` verbatim to `http://unix:/tmp/llama.sock:/v1/chat/completions` (Node.js built-in `http.request` with `socketPath`). For each line of the SSE response, call `onChunk(line)`. Detect `data: [DONE]` and resolve the promise. On `signal` abort: call `req.destroy()` then call `flushSlot()`. Keep `flushSlot(): Promise<boolean>` unchanged. | `src/inference-proxy.ts` | `[x]` |
| 1-2 | Update `InferenceProxyDeps` if needed. Update `src/index.ts` wiring if any interface references changed. Verify `npm run build` (esbuild) and `npm run typecheck` pass. | `src/inference-proxy.ts`, `src/index.ts` | `[x]` |
| 1-3 | Rewrite unit tests for `InferenceProxy`. Cases: `forwardInference` issues `POST /v1/chat/completions` with the correct body; SSE lines are emitted via `onChunk`; `data: [DONE]` triggers `flushSlot()` and resolves the promise; aborting via `AbortSignal` calls `req.destroy()` and then `flushSlot()`; `flushSlot` returns `false` on non-2xx and on timeout. | `tests/unit/inference-proxy.test.ts` | `[x]` |

---

## Phase 2 — Session Manager rewrite

Replace the Phase 1 single-prompt message loop with a multi-turn inference loop. The session stays open and the slot stays held between turns.

| #   | Task | File / Location | Status |
|-----|------|-----------------|:------:|
| 2-1 | Update the Session Manager's post-`session_ack` handler to enter an **inference loop**: (a) wait for the next NDJSON message; (b) if `type === 'inference_request'`, reset the idle timer, create an `AbortController`, call `inferenceProxy.forwardInference(msg.body, onChunk, controller.signal)`; for each `sseLine` received via `onChunk`, write an `inference_response_chunk` message to the socket; await the promise, then loop back to (a); (c) if `type === 'session_close'`, exit the loop and tear down; (d) unknown types are logged and ignored. Remove all `PromptPayload` / `ResponseChunk` / `PromptCancel` / `PromptCancelled` handling. | `src/session-manager.ts` | `[x]` |
| 2-2 | Socket teardown during inference: attach a handler so that when the TLS socket emits `'close'` or `'error'` while an inference is in progress, the `AbortController.abort()` is called immediately. After the `forwardInference` promise settles (whether via abort or natural completion), call `flushSlot()`; if it returns `false`, call `process.exit(1)`. | `src/session-manager.ts` | `[x]` |
| 2-3 | Idle timer update: the idle timer now resets on each `inference_request` (not on each prompt). The timeout remains configurable (default 30 minutes). On expiry during active inference: abort the `AbortController` first, then send `session_timeout` and close. On expiry while idle (waiting for next request): send `session_timeout` and close. | `src/session-manager.ts` | `[x]` |
| 2-4 | Update `src/index.ts` wiring: remove any references to Phase 1 session types; verify end-to-end compile (`npm run build`, `npm run typecheck`). Update the `SessionManagerDeps` interface if it changed. | `src/index.ts`, `src/session-manager.ts` | `[x]` |

---

## Phase 3 — Unit tests

| #   | Task | File / Location | Status |
|-----|------|-----------------|:------:|
| 3-1 | Rewrite Session Manager unit tests. Cases: `session_open` with valid token → `session_ack` then enters inference loop; `inference_request` → `forwardInference` called with correct body; `inference_response_chunk` messages are written for each SSE line; loop continues after first turn completes; `session_close` exits loop gracefully; socket close mid-inference → `AbortController.abort()` called; idle timer expiry during waiting → `session_timeout` sent. | `tests/unit/session-manager.test.ts` | `[x]` |
| 3-2 | Verify existing Router Client unit tests still pass without modification (Router Client is unchanged in Phase 2). Run `npm run test:unit`. | `tests/unit/router-client.test.ts` | `[x]` |
| 3-3 | Update `tests/unit/config.test.ts` if config schema changed. Verify all unit tests pass: `npm run test:unit`. | `tests/unit/config.test.ts` | `[x]` |

---

## Phase 4 — Integration tests

| #   | Task | File / Location | Status |
|-----|------|-----------------|:------:|
| 4-1 | Update integration test helpers (`tests/integration/helpers.ts`). Remove Phase 1 `PromptPayload` / `ResponseChunk` fixtures; add helpers that send `inference_request` messages and collect `inference_response_chunk` streams. Update mock router helpers to reflect the Phase 0 protocol changes. | `tests/integration/helpers.ts` | `[ ]` |
| 4-2 | Rewrite integration tests. Cases: full session open → inference_request → SSE stream → inference_response_chunk stream → session stays open for second turn → session_close; socket abort mid-inference → `flushSlot` is called; host-busy rejection; idle timeout while waiting for next turn. Run `npm run test:integration`. | `tests/integration/session.test.ts` (create/update) | `[ ]` |

---

## Status ledger

Update this table whenever a task changes state.

| Phase | Title | Total | Done | In progress | Blocked | Remaining |
|-------|-------|:-----:|:----:|:-----------:|:-------:|:---------:|
| 0 | `sharegrid-shared` protocol update | 3 | 3 | 0 | 0 | 0 |
| 1 | Inference Proxy rewrite | 3 | 3 | 0 | 0 | 0 |
| 2 | Session Manager rewrite | 4 | 4 | 0 | 0 | 0 |
| 3 | Unit tests | 3 | 3 | 0 | 0 | 0 |
| 4 | Integration tests | 2 | 0 | 0 | 0 | 2 |
| — | **Total** | **15** | **13** | **0** | **0** | **2** |

### Notes / blockers

- **Phases 0–3 complete.** `forwardInference` implemented (raw SSE pass-through, abort+flush), Session Manager inference loop implemented (multi-turn, abort-aware teardown, idle timer reset per turn), all unit tests green (120 total).
- **Phase 4 (integration tests)** is the remaining work. The mock host helper needs extending to speak the Phase 2 `inference_request`/`inference_response_chunk` protocol.

---

## Conventions reminder for implementers

- Source files: `kebab-case.ts`. Functions/variables: `camelCase`. (See `implementation_guidelines.md` §3.)
- Named exports only. No default exports.
- `async`/`await` only. No raw `.then()` chains.
- No `TODO` comments merged to `main` — open an issue instead.
- Conventional Commits with scope `host`: e.g. `feat(host): rewrite inference-proxy as raw openai pass-through`.
- One PR per task or per tightly related task cluster. CI must be green before merge.
