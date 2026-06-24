# LLMHost — Phase 3 Implementation Plan

> **Scope:** Phase 3 — concurrent sessions, slot-aware inference proxy, and live availability reporting. Companion to [`architecture_llmhost.md`](./architecture_llmhost.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 3 LLMHost changes into small, agent-sized tasks.
>
> **Prerequisite:** `implementation_plan_shared.md` Phase 1 must be complete and the `sharegrid-host/sharegrid-shared` submodule pointer must be updated before starting here.

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
| 0 | Config + llama-launcher | 4 | Shared protocol Phase 1 |
| 1 | InferenceProxy — slot-aware | 4 | Phase 0 |
| 2 | SessionManager — capacity counter | 6 | Phase 1 |
| 3 | RouterClient — load reporting | 4 | Phase 2 |
| 4 | Unit tests | 4 | Phase 3 |
| 5 | Integration tests | 3 | Phase 4 |

---

## Phase 0 — Config + llama-launcher

Add `SHAREGRID_MAX_SESSIONS` to configuration and thread it through to llama-server's `--parallel` flag. Default of `1` preserves all Phase 1–2 behaviour.

| # | Task | File | Status |
|---|------|------|:------:|
| H3-1 | Add `SHAREGRID_MAX_SESSIONS: z.coerce.number().int().min(1).max(32).default(1)` to `ConfigSchema`. Include it in the exported `Config` type. | `src/config.ts` | `[ ]` |
| H3-2 | Update `launchLlama` to accept `maxSessions: number` in its `deps` parameter. Replace the hardcoded `'--parallel', '1'` argument with `'--parallel', String(maxSessions)`. | `src/llama-launcher.ts` | `[ ]` |
| H3-3 | Update `src/index.ts`: pass `config.SHAREGRID_MAX_SESSIONS` to `launchLlama`. | `src/index.ts` | `[ ]` |
| H3-4 | Update `tests/unit/config.test.ts`: add cases for `SHAREGRID_MAX_SESSIONS` — default is `1` when absent; accepts `1`, `4`, `32`; rejects `0`, `33`, non-integer strings. Run `npm run test:unit`. | `tests/unit/config.test.ts` | `[ ]` |

---

## Phase 1 — InferenceProxy: slot-aware forwarding and flush

Add a `slotId` parameter to both public methods. `forwardInference` injects `"id_slot": slotId` into the request body before POSTing to llama.cpp, directing it to the correct KV-cache slot. `flushSlot` targets `DELETE /slots/<slotId>` instead of the hardcoded `/slots/0`.

| # | Task | File | Status |
|---|------|------|:------:|
| H3-5 | Update the `InferenceProxy` interface: change `forwardInference` signature to `forwardInference(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal, slotId: number): Promise<void>`. | `src/inference-proxy.ts` | `[ ]` |
| H3-6 | Implement `slotId` injection in `forwardInference`: parse `body` as JSON, set `parsedBody.id_slot = slotId`, re-stringify. Use the modified string (not the original `body`) as the POST payload. Update `Content-Length` accordingly. | `src/inference-proxy.ts` | `[ ]` |
| H3-7 | Update the `InferenceProxy` interface and implementation: change `flushSlot` signature to `flushSlot(slotId: number): Promise<boolean>`. Change the request path from the hardcoded `'/slots/0'` to `` `/slots/${slotId}` ``. Update the abort handler inside `forwardInference` to pass `slotId` when calling `flushSlot(slotId)`. | `src/inference-proxy.ts` | `[ ]` |
| H3-8 | Update `tests/unit/inference-proxy.test.ts`: all existing `forwardInference` test cases gain a `slotId` argument (use `0` for single-slot cases to maintain backward compatibility); add a case asserting `id_slot: 0` is present in the body sent to llama.cpp; add a case with `slotId: 3` asserting `id_slot: 3`; update `flushSlot` test cases to assert the correct path (e.g. `/slots/0`, `/slots/3`). Run `npm run test:unit`. | `tests/unit/inference-proxy.test.ts` | `[ ]` |

---

## Phase 2 — SessionManager: capacity counter

Replace the binary `slotOccupied: boolean` with a `Set<number>` of active slot IDs. Each session is assigned a unique slot ID on open and releases it on teardown. The slot ID is threaded through to the InferenceProxy so llama.cpp uses the right KV-cache slot.

| # | Task | File | Status |
|---|------|------|:------:|
| H3-9 | Add `maxSessions: number` and `onSessionCountChange: (activeSessions: number) => void` to `SessionManagerDeps`. Add `getActiveSessions(): number` to the `SessionManager` interface — returns the current occupied slot count. | `src/session-manager.ts` | `[ ]` |
| H3-10 | Replace `slotOccupied: boolean` with `activeSlots: Set<number>`. Rewrite `acquireSlot()`: iterate `0..maxSessions-1`, find the first ID not in `activeSlots`, add it, call `onSessionCountChange(activeSlots.size)`, and return the ID; return `null` if no free slot exists. Rewrite `releaseSlot(slotId: number)`: remove `slotId` from the set, call `onSessionCountChange(activeSlots.size)`. | `src/session-manager.ts` | `[ ]` |
| H3-11 | Thread `slotId` through the per-connection session context: `acquireSlot()` result (`number | null`) is stored in a `let slotId: number | null` variable scoped to the connection handler; `null` means no slot was acquired. Pass `slotId` to `inferenceProxy.forwardInference(msg.body, onChunk, signal, slotId)`. Pass `slotId` to `inferenceProxy.flushSlot(slotId)` inside `teardown`. | `src/session-manager.ts` | `[ ]` |
| H3-12 | Update `handleSessionOpen`: after `acquireSlot()` returns `null`, send `session_reject: busy` and close — unchanged logic, but the condition is now `acquireSlot() === null` instead of `slotOccupied`. | `src/session-manager.ts` | `[ ]` |
| H3-13 | Implement `getActiveSessions(): number` on the returned object: returns `activeSlots.size`. | `src/session-manager.ts` | `[ ]` |
| H3-14 | Update `src/index.ts` wiring: pass `config.SHAREGRID_MAX_SESSIONS` as `maxSessions` in `SessionManagerDeps`. Wire `onSessionCountChange` temporarily as a no-op (`() => {}`); it will be replaced in Phase 3 task H3-19 once `RouterClient.reportStatus` exists. | `src/index.ts` | `[ ]` |

---

## Phase 3 — RouterClient: load reporting

Extend the RouterClient to include `maxSessions` and `contextSize` in the registration payload, `activeSessions` in heartbeats, and a new `reportStatus` method for immediate availability signalling.

| # | Task | File | Status |
|---|------|------|:------:|
| H3-15 | Add `maxSessions: number`, `contextSize: number`, and `getActiveSessions: () => number` to `RouterClientDeps`. Include `maxSessions` and `contextSize` in the `RegistrationPayload` sent to the router. Include `activeSessions: getActiveSessions()` in every `HeartbeatPayload`. | `src/router-client.ts` | `[ ]` |
| H3-16 | Add `reportStatus(activeSessions: number): void` to the `RouterClient` interface. Implementation: if the router socket is alive and not destroyed, send `{ v: PROTOCOL_VERSION, type: 'host_status_update', hostId, activeSessions }` via `sendMessage`. No-op if not yet registered (no `hostId`) or if the socket is gone — the next heartbeat will reconcile the value. | `src/router-client.ts` | `[ ]` |
| H3-17 | Update `connectAndRegister` to read `contextSize` from deps and include it in the payload. No other changes to the registration or reconnect logic. | `src/router-client.ts` | `[ ]` |
| H3-18 | Update `src/index.ts` wiring: pass `config.SHAREGRID_MAX_SESSIONS` as `maxSessions`, `config.SHAREGRID_MODEL_CONTEXT_SIZE` as `contextSize`, and `() => sessionManager.getActiveSessions()` as `getActiveSessions` to `RouterClientDeps`. Replace the temporary no-op `onSessionCountChange` in `SessionManagerDeps` with `(n) => routerClient.reportStatus(n)`. Note: `routerClient` must be assigned before `sessionManager` is created, or use a late-binding wrapper `(n) => routerClient?.reportStatus(n)` if the construction order requires it. | `src/index.ts` | `[ ]` |

---

## Phase 4 — Unit tests

| # | Task | File | Status |
|---|------|------|:------:|
| H3-19 | Update `tests/unit/config.test.ts`: verify `SHAREGRID_MAX_SESSIONS` is covered (added in Phase 0 task H3-4 — mark complete if already done). | `tests/unit/config.test.ts` | `[ ]` |
| H3-20 | Update `tests/unit/session-manager.test.ts`. Add or update cases: (a) `acquireSlot` with `maxSessions: 1` returns `0` on first call, `null` on second — existing "busy" case now checks `null` return; (b) `acquireSlot` with `maxSessions: 3` returns `0`, `1`, `2` on successive calls, `null` on the fourth; (c) releasing slot `1` makes it available again; (d) `onSessionCountChange` is called after each acquire (with `1`) and each release (with decremented count); (e) `getActiveSessions()` returns the current set size; (f) `slotId` is passed to `forwardInference` and `flushSlot` spy mocks — verify the correct slot ID is forwarded. Run `npm run test:unit`. | `tests/unit/session-manager.test.ts` | `[ ]` |
| H3-21 | Update `tests/unit/router-client.test.ts`. Add or update cases: (a) `RegistrationPayload` sent to the router includes `maxSessions` and `contextSize`; (b) `HeartbeatPayload` includes `activeSessions` matching `getActiveSessions()` return value at call time; (c) `reportStatus(N)` sends a `host_status_update` message with `activeSessions: N` when the socket is alive; (d) `reportStatus` is a no-op when not yet registered; (e) `reportStatus` is a no-op when the socket is destroyed. Run `npm run test:unit`. | `tests/unit/router-client.test.ts` | `[ ]` |
| H3-22 | Verify all other existing unit tests still pass without modification: `tests/unit/model-scanner.test.ts`, `tests/unit/inference-proxy.test.ts` (updated in Phase 1). Run `npm run typecheck && npm run lint && npm run test:unit`. | various | `[ ]` |

---

## Phase 5 — Integration tests

| # | Task | File | Status |
|---|------|------|:------:|
| H3-23 | Update all existing integration tests in `tests/integration/` to supply the new required deps: `maxSessions`, `contextSize`, `getActiveSessions`, `onSessionCountChange` in `SessionManagerDeps`; `maxSessions`, `contextSize`, `getActiveSessions` in `RouterClientDeps`. Verify all existing integration tests still pass: `npm run test:integration`. | `tests/integration/` | `[ ]` |
| H3-24 | Add integration test — concurrent sessions: create a host with `maxSessions: 2`; open two simultaneous `session_open` connections (both should receive `session_ack`); attempt a third — it should receive `session_reject: busy`; close one of the two sessions; the third attempt should now succeed. Use the fake router helper from `tests/integration/helpers.ts`. Run `npm run test:integration`. | `tests/integration/session.test.ts` | `[ ]` |
| H3-25 | Add integration test — status reporting: spy on the fake router's received messages; open a session and assert that a `host_status_update` with `activeSessions: 1` was sent; close the session and assert a second `host_status_update` with `activeSessions: 0` was sent; also assert that the heartbeat messages carry the correct `activeSessions` value. Run `npm run test:integration`. | `tests/integration/router-client.test.ts` | `[ ]` |

---

## Completion ledger

| Phase | Status | Notes |
|-------|:------:|-------|
| 0 — Config + llama-launcher | `[ ]` | |
| 1 — InferenceProxy | `[ ]` | |
| 2 — SessionManager | `[ ]` | |
| 3 — RouterClient | `[ ]` | |
| 4 — Unit tests | `[ ]` | |
| 5 — Integration tests | `[ ]` | |

---

## Next steps after completion

Proceed to `implementation_plan_llmuser.md`. Host and user implementation can overlap once the shared protocol submodule pointer is updated — the user does not depend on the host implementation, only on the shared protocol types.
