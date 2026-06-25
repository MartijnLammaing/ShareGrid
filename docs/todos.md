# Phase 3 — Active Task List

> This file tracks the current sub-phase's outstanding tasks. It is cleared when a sub-phase PR is merged and repopulated for the next sub-phase.
>
> Current sub-phase: **3.2 — Router (LLMRouter)**
> Branch: `phase-3/router` (in `sharegrid-router` repo, created from `a1aaba8`)
> Top-level branch: `phase-3/protocol`

---

## Sub-phase 3.1 — sharegrid-shared protocol additions — CLOSED ✅

Shared repo committed @ `fbfc44a` on `origin/main`; all three nested pointers advanced; shared typecheck/lint/78 tests green. Consumer typecheck red by design — fixed in 3.2/3.3/3.4.

---

## Sub-phase 3.2 — LLMRouter

See `implementation_plan_llmrouter.md` for full task descriptions. All changes are in the `sharegrid-router` repo. The nested `sharegrid-shared` pointer is already advanced to `fbfc44a` (uncommitted in working tree).

### Phase 0 — HostRegistry: availability fields (`src/host-registry.ts`)

- [x] **R3-1** — Add `contextSize`, `maxSessions`, `activeSessions` to `HostEntry`. `contextSize`+`maxSessions` from registration; `activeSessions` starts at 0.
- [x] **R3-2** — Verify `add()` stores all fields (spread already covers; no signature change).
- [x] **R3-3** — Change `updateHeartbeat` signature to `(hostId, newToken, activeSessions, now)`: store `activeSessions` alongside `lastSeen`/`hostKeyToken`.
- [x] **R3-4** — Add `updateStatus(hostId, activeSessions): boolean` — sets `activeSessions`, does NOT update `lastSeen`; `false` if unknown.
- [x] **R3-5** — Update `list()` to include `contextSize`, `availableSlots` (`max(0, maxSessions-activeSessions)`), `totalSlots` (`maxSessions`).

### Phase 1 — TLS Listener (`src/tls-listener.ts`)

- [x] **R3-6** — `isValidRegistrationPayload`: validate `contextSize` (positive int) + `maxSessions` (int 1–32); reject if absent/out-of-range.
- [x] **R3-7** — `handleHostConnection`: extract `contextSize`+`maxSessions` from payload; set `activeSessions: 0` on new `HostEntry`.
- [x] **R3-8** — Rename `handleHeartbeat` → `handleHostMessage`; dispatch on `msg.type`: `heartbeat` (extract `activeSessions`, pass to `updateHeartbeat`); `host_status_update` (validate `hostId` match + `activeSessions` int, call `updateStatus`, debug log, no token/lastSeen update); else warn+close.

### Phase 2 — Unit tests

- [x] **R3-9** — `tests/unit/host-registry.test.ts`: add/update `contextSize`/`maxSessions`/`activeSessions` storage; `updateHeartbeat` new param; `updateStatus` true/false; `list()` computes `availableSlots` (normal/full/over-full guard) + `contextSize`/`totalSlots`.
- [x] **R3-10** — `tests/unit/tls-listener.test.ts`: valid registration with new fields; missing/out-of-range `contextSize`/`maxSessions` closes; heartbeat carries `activeSessions`; `host_status_update` valid/wrong-hostId/bad-activeSessions; host_list_response includes new fields.

### Phase 3 — Integration tests

- [x] **R3-11** — Update all `tests/integration/` registration payloads to include `contextSize`+`maxSessions` (heartbeat `activeSessions`); assert host list has `availableSlots`/`totalSlots`/`contextSize`.
- [x] **R3-12** — New `tests/integration/host-list.test.ts` case: host registers `maxSessions:2`; `host_status_update` `activeSessions:1` → user sees `availableSlots:1`; `activeSessions:2` → `availableSlots:0`.

**Sub-phase 3.2 done when:** `npm run typecheck && npm run lint && npm run test:unit && npm run test:integration` green in `sharegrid-router`.
      — **3.2 COMPLETE.** typecheck ✅ lint ✅ 163 unit tests ✅ 14 integration tests ✅.

---

## Upcoming sub-phases (not started)

- **3.3 — Host** (`implementation_plan_llmhost.md`): Config, llama-launcher, InferenceProxy slot-ID, SessionManager capacity counter, RouterClient load reporting
- **3.4 — User** (`implementation_plan_llmuser.md`): SessionClient isInferenceActive, HostSessionPool multi-session, ModelRegistry resolveHosts, ApiServer retry loop
