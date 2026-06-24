# LLMUser — Phase 3 Implementation Plan

> **Scope:** Phase 3 — availability-aware host selection, multi-session pool with conversation affinity, and aggregated slot metadata in the OpenAI model list. Companion to [`architecture_llmuser.md`](./architecture_llmuser.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 3 LLMUser changes into small, agent-sized tasks.
>
> **Prerequisite:** `implementation_plan_shared.md` Phase 1 must be complete and the `sharegrid-user/sharegrid-shared` submodule pointer must be updated before starting here. The LLMUser does not depend on the router or host implementations — only on the shared protocol types.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** field. When a task is complete, update its status and the summary ledger at the bottom.
3. Complete phases in order.

### Status legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete (merged, CI green) |
| `[!]` | Blocked — see notes |

---

## Phase overview

| Phase | Title | Tasks | Depends on |
|-------|-------|:-----:|------------|
| 0 | SessionClient — `isInferenceActive()` | 2 | Shared protocol Phase 1 |
| 1 | HostSessionPool — multi-session with conversation affinity | 4 | Phase 0 |
| 2 | ModelRegistry — availability-aware selection | 4 | Phase 0 |
| 3 | ApiServer — retry loop + slot metadata | 3 | Phases 1 + 2 |
| 4 | Integration tests | 4 | Phase 3 |

---

## Phase 0 — SessionClient: `isInferenceActive()`

Add a method that lets the Host Session Pool distinguish idle sessions from those currently performing inference. This is the key primitive enabling conversation affinity.

| # | Task | File | Status |
|---|------|------|:------:|
| U3-1 | Add `isInferenceActive(): boolean` to the `SessionClient` interface. Implementation: add a private `inferenceActive = false` flag; set it to `true` at the start of `sendInferenceRequest` (before the `return new Promise(...)` call); set it back to `false` in both `resolveActiveInference()` and `rejectActiveInference()`. Expose via `isInferenceActive(): boolean { return inferenceActive; }` on the returned object. | `src/session-client.ts` | `[ ]` |
| U3-2 | Update `tests/unit/session-client.test.ts`: (a) `isInferenceActive()` returns `false` before `sendInferenceRequest` is called; (b) `isInferenceActive()` returns `true` while a `sendInferenceRequest` promise is pending (use a mock that doesn't resolve immediately); (c) `isInferenceActive()` returns `false` after the promise resolves; (d) `isInferenceActive()` returns `false` after the promise rejects (e.g. `SessionTimeoutError`). Run `npm run test:unit`. | `tests/unit/session-client.test.ts` | `[ ]` |

---

## Phase 1 — HostSessionPool: multi-session with conversation affinity

Replace the single-session-per-host map with a list-per-host. The acquire algorithm implements conversation affinity: a sequential caller always receives the same idle session; concurrent callers each get their own.

| # | Task | File | Status |
|---|------|------|:------:|
| U3-3 | Change the internal map from `Map<string, SessionClient>` to `Map<string, SessionClient[]>`. Update the type annotation and initialisation. | `src/host-session-pool.ts` | `[ ]` |
| U3-4 | Rewrite `acquire(host: HostListEntry): Promise<SessionClient>`: (1) get or initialise the list for `host.hostId`; (2) prune dead sessions in-place: `list = list.filter(s => s.isAlive()); sessions.set(host.hostId, list)`; (3) find `const idle = list.find(s => !s.isInferenceActive())`; (4) if `idle` exists, return it (conversation-affinity path); (5) otherwise: `const client = createSessionClient({ logger }); await client.openSession(host);` — throws `HostBusyError` or `TlsFingerprintError` on failure (propagate, do not store the failed client); on success: `list.push(client); return client`. | `src/host-session-pool.ts` | `[ ]` |
| U3-5 | Rewrite `closeAll()`: for each entry in the map, close every session in the list. `const closing = [...sessions.values()].flatMap(list => list.map(s => s.closeSession().catch(...)))`; await all; `sessions.clear()`. | `src/host-session-pool.ts` | `[ ]` |
| U3-6 | Update `tests/unit/host-session-pool.test.ts`. Add or update cases: (a) first `acquire` opens a new session and stores it; (b) second `acquire` for the same host (session alive, not inferring) returns the same session — no new `openSession` call; (c) when the existing session `isInferenceActive()` returns `true`, a second `acquire` opens a new session; (d) dead sessions are pruned before the idle search — a dead session is not returned; (e) `HostBusyError` thrown by `openSession` propagates out of `acquire` with no session stored; (f) `closeAll()` calls `closeSession()` on all sessions in all lists. Run `npm run test:unit`. | `tests/unit/host-session-pool.test.ts` | `[ ]` |

---

## Phase 2 — ModelRegistry: availability-aware selection

Extend the cached data and model-object shape to include slot metadata. Add `resolveHosts` for the API Server's retry loop.

| # | Task | File | Status |
|---|------|------|:------:|
| U3-7 | Extend the `OpenAIModel` interface: add `context_length: number`, `sharegrid_available_slots: number`, and `sharegrid_total_slots: number`. These fields appear on every model object returned by `getModels()`. | `src/model-registry.ts` | `[ ]` |
| U3-8 | Update `refresh()` to aggregate across all hosts that share the same `modelName`. When building the `OpenAIModel` list: group `HostListEntry` objects by `modelName`; for each group compute `context_length` (use the first entry's `contextSize` — all hosts serving the same model should report the same value), `sharegrid_available_slots` (sum of `availableSlots`), `sharegrid_total_slots` (sum of `totalSlots`). The existing `models` and `entries` cache remains but `entries` now stores all raw `HostListEntry` objects (not deduplicated). | `src/model-registry.ts` | `[ ]` |
| U3-9 | Add `resolveHosts(modelId: string): Promise<HostListEntry[]>` to the `ModelRegistry` interface. Implementation: ensure the cache is fresh; filter `cache.entries` for `e.modelName === modelId`; sort so entries with `availableSlots > 0` come first (stable sort — preserve registration order within each group); throw `HostNotFoundError` if the filtered list is empty; return the sorted list. | `src/model-registry.ts` | `[ ]` |
| U3-10 | Update `tests/unit/model-registry.test.ts`. Add or update cases: (a) `getModels()` returns `context_length`, `sharegrid_available_slots`, `sharegrid_total_slots` on each model object; (b) two hosts with the same `modelName` produce one model entry with summed slot counts; (c) `resolveHosts` returns all matching hosts sorted available-first; (d) `resolveHosts` throws `HostNotFoundError` if no host matches; (e) `resolveHost` (existing single-host resolver, used by CLI) returns the first available host (i.e. first entry in the `resolveHosts` result order). Run `npm run test:unit`. | `tests/unit/model-registry.test.ts` | `[ ]` |

---

## Phase 3 — ApiServer: retry loop + slot metadata in model list

Replace the single `resolveHost` call with an ordered-list retry loop, and surface slot metadata in the `/v1/models` response.

| # | Task | File | Status |
|---|------|------|:------:|
| U3-11 | In `handleChatCompletions`, replace `modelRegistry.resolveHost(model)` with `modelRegistry.resolveHosts(model)` to obtain an ordered `HostListEntry[]`. Iterate the list: for each host, attempt `sessionPool.acquire(host)`; on `HostBusyError` log at `debug` level and continue to the next; on any other error (e.g. `TlsFingerprintError`) log at `warn`, invalidate the cache, and continue; if a session is successfully acquired, break the loop and proceed. If the loop completes without a successful acquire, return `503` with a clear "all hosts busy" message. | `src/api-server.ts` | `[ ]` |
| U3-12 | The `GET /v1/models` handler already calls `modelRegistry.getModels()` and returns the result as-is. No change needed to the handler itself — `getModels()` now returns the enriched objects (from Model Registry Phase 2). Verify `npm run typecheck` passes (the `OpenAIModel` interface change must be compatible). | `src/api-server.ts` | `[ ]` |
| U3-13 | Update `tests/unit/api-server.test.ts`. Add or update cases: (a) when the first host in the resolved list is busy, the second host is tried; (b) when all hosts are busy, 503 is returned; (c) a non-`HostBusyError` (e.g. `TlsFingerprintError`) on the first host triggers cache invalidation and tries the next host; (d) `GET /v1/models` response includes `sharegrid_available_slots` and `sharegrid_total_slots` on each model object. Run `npm run test:unit`. | `tests/unit/api-server.test.ts` | `[ ]` |

---

## Phase 4 — Integration tests

| # | Task | File | Status |
|---|------|------|:------:|
| U3-14 | Update all existing integration tests in `tests/integration/` to supply `availableSlots`, `totalSlots`, and `contextSize` on mock `HostListEntry` objects wherever they are constructed. Verify all existing integration tests still pass: `npm run test:integration`. | `tests/integration/` | `[ ]` |
| U3-15 | Add integration test — multi-host model routing: construct a mock with two hosts serving the same model name; first host has `availableSlots: 0`; second has `availableSlots: 1`; the first `session_open` should route to the second host (the pool opens a new session there, not to the "full" first host). Verify via spy on `createSessionClient` or by checking which endpoint was dialled. | `tests/integration/server.test.ts` | `[ ]` |
| U3-16 | Add integration test — all-hosts-busy: both hosts for the same model have `availableSlots: 0` and both reject with `session_reject: busy`; `POST /v1/chat/completions` returns `503`. | `tests/integration/rejections.test.ts` | `[ ]` |
| U3-17 | Add integration test — conversation affinity: make two sequential `POST /v1/chat/completions` calls for the same model; spy on `createSessionClient`; assert it is called only once (the second request reuses the session opened by the first). | `tests/integration/happy-path.test.ts` | `[ ]` |

---

## Completion ledger

| Phase | Status | Notes |
|-------|:------:|-------|
| 0 — SessionClient | `[ ]` | |
| 1 — HostSessionPool | `[ ]` | |
| 2 — ModelRegistry | `[ ]` | |
| 3 — ApiServer | `[ ]` | |
| 4 — Integration tests | `[ ]` | |

---

## Next steps after completion

All four Phase 3 implementation plans are complete. Open a PR for each sub-phase branch and merge to `main`. Once `main` is green across all three component repos and `sharegrid-shared`, create the phase completion summary at `docs/phase_3_summary.md` and archive the four implementation plan documents to `docs/archived/phase_3/`.
