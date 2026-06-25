# LLMRouter — Phase 3 Implementation Plan

> **Scope:** Phase 3 — multi-host availability tracking. Companion to [`architecture_llmrouter.md`](./architecture_llmrouter.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 3 LLMRouter changes into small, agent-sized tasks.
>
> **Prerequisite:** `implementation_plan_shared.md` Phase 1 must be complete and the `sharegrid-router/sharegrid-shared` submodule pointer must be updated before starting here.

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
| 0 | HostRegistry — availability fields | 5 | Shared protocol Phase 1 |
| 1 | TLS Listener — registration, heartbeat, status update | 3 | Phase 0 |
| 2 | Unit tests | 2 | Phase 1 |
| 3 | Integration tests | 2 | Phase 2 |

---

## Phase 0 — HostRegistry: availability fields

Extend the in-memory host registry to track session capacity and current load. All changes are in `src/host-registry.ts`.

| # | Task | File | Status |
|---|------|------|:------:|
| R3-1 | Add `contextSize: number`, `maxSessions: number`, and `activeSessions: number` to the `HostEntry` interface. `contextSize` is received at registration (fixes the pre-existing gap). `maxSessions` is received at registration. `activeSessions` starts at `0` and is updated by heartbeats and `host_status_update` messages. | `src/host-registry.ts` | `[x]` |
| R3-2 | Update `HostRegistry.add(entry: HostEntry)` — no signature change needed; the new fields are part of `HostEntry` already. Verify the implementation stores all fields (no fields are dropped in the spread). | `src/host-registry.ts` | `[x]` |
| R3-3 | Update `HostRegistry.updateHeartbeat` signature to `updateHeartbeat(hostId: string, newToken: string, activeSessions: number, now: number): boolean`. Store `activeSessions` on the entry alongside `lastSeen` and `hostKeyToken`. | `src/host-registry.ts` | `[x]` |
| R3-4 | Add `HostRegistry.updateStatus(hostId: string, activeSessions: number): boolean`. Implementation: look up the entry; if missing return `false`; otherwise set `entry.activeSessions = activeSessions` and return `true`. Does **not** update `lastSeen` — status updates are not heartbeats. | `src/host-registry.ts` | `[x]` |
| R3-5 | Update `HostRegistry.list()` to include `contextSize`, `availableSlots`, and `totalSlots` in each `HostListEntry`. Compute: `availableSlots = Math.max(0, entry.maxSessions - entry.activeSessions)`, `totalSlots = entry.maxSessions`. | `src/host-registry.ts` | `[x]` |

---

## Phase 1 — TLS Listener: registration, heartbeat, status update

Extend the TLS Listener to handle the updated registration payload, the `activeSessions`-bearing heartbeat, and the new `host_status_update` message. All changes are in `src/tls-listener.ts`.

| # | Task | File | Status |
|---|------|------|:------:|
| R3-6 | Update `isValidRegistrationPayload`: add validation for `contextSize` (positive integer) and `maxSessions` (integer in range 1–32). Both are required fields; reject the connection if either is absent or out of range. | `src/tls-listener.ts` | `[x]` |
| R3-7 | Update `handleHostConnection`: extract `registration.contextSize` and `registration.maxSessions` from the validated payload; include them in the `HostEntry` passed to `hostRegistry.add`. Set `activeSessions: 0` on the new entry. | `src/tls-listener.ts` | `[x]` |
| R3-8 | Rename the inner data handler from `handleHeartbeat` to `handleHostMessage`. Inside it, dispatch on `msg.type`: (a) `'heartbeat'` — existing logic, but now also extract `msg.activeSessions` (validated as a non-negative integer) and pass it to `hostRegistry.updateHeartbeat(hostId, newToken, activeSessions, now)`; (b) `'host_status_update'` — validate `msg.hostId === hostId` (close connection if mismatch); validate `msg.activeSessions` as a non-negative integer (close if invalid); call `hostRegistry.updateStatus(hostId, msg.activeSessions)`; log at `debug` level; (c) any other type — log warn and close (unchanged). The `host_status_update` path does **not** issue a new host key token or update `lastSeen`. | `src/tls-listener.ts` | `[x]` |

---

## Phase 2 — Unit tests

| # | Task | File | Status |
|---|------|------|:------:|
| R3-9 | Update `tests/unit/host-registry.test.ts`. Add or update cases: (a) `add` stores `contextSize`, `maxSessions`, `activeSessions`; (b) `updateHeartbeat` with the new `activeSessions` parameter updates `entry.activeSessions`; (c) `updateStatus` updates `activeSessions` and returns `true`; `updateStatus` on an unknown host returns `false`; (d) `list()` computes `availableSlots` correctly — `maxSessions: 2, activeSessions: 1 → availableSlots: 1`; full host (`activeSessions === maxSessions`) → `availableSlots: 0`; over-full (guard against negative) `activeSessions > maxSessions` → `availableSlots: 0`; (e) `list()` includes `contextSize` and `totalSlots`. Run `npm run test:unit` and confirm all pass. | `tests/unit/host-registry.test.ts` | `[x]` |
| R3-10 | Update `tests/unit/tls-listener.test.ts`. Add or update cases: (a) valid registration with `contextSize` and `maxSessions` fields succeeds; missing or out-of-range `contextSize` or `maxSessions` causes the connection to be closed with no registry write; (b) heartbeat message now includes `activeSessions: N`; `updateHeartbeat` is called with the correct `activeSessions` value; (c) `host_status_update` after registration: valid message updates the registry via `updateStatus`; message with wrong `hostId` closes the connection; message with non-integer `activeSessions` closes the connection; (d) `host_list_response` sent to a user includes `availableSlots`, `totalSlots`, and `contextSize` on each entry. Run `npm run test:unit`. | `tests/unit/tls-listener.test.ts` | `[x]` |

---

## Phase 3 — Integration tests

| # | Task | File | Status |
|---|------|------|:------:|
| R3-11 | Update all existing integration tests in `tests/integration/` to include `contextSize` and `maxSessions` in registration payloads (and `activeSessions` in heartbeat payloads). Assert that host list responses now contain `availableSlots`, `totalSlots`, and `contextSize`. Run `npm run test:integration`. | `tests/integration/` | `[x]` |
| R3-12 | Add new integration test: a host registers with `maxSessions: 2` and `activeSessions: 0`; sends a `host_status_update` with `activeSessions: 1`; a user immediately fetches the host list and receives `availableSlots: 1`, `totalSlots: 2`. Add a second case: host sends `host_status_update` with `activeSessions: 2`; user sees `availableSlots: 0`. Run `npm run test:integration`. | `tests/integration/host-list.test.ts` | `[x]` |

---

## Completion ledger

| Phase | Status | Notes |
|-------|:------:|-------|
| 0 — HostRegistry | `[x]` | |
| 1 — TLS Listener | `[x]` | |
| 2 — Unit tests | `[x]` | 163 unit tests pass |
| 3 — Integration tests | `[x]` | 14 integration tests pass (incl. new host_status_update availability case) |

---

## Next steps after completion

Proceed to `implementation_plan_llmhost.md`. Router and host implementation can overlap once the shared protocol submodule pointer is updated.
