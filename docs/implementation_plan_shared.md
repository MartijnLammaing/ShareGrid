# sharegrid-shared — Phase 3 Implementation Plan

> **Scope:** Phase 3 — multi-host availability. Companion to [`architecture_overview.md`](./architecture_overview.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document covers two concerns: (1) updating the architecture documents to reflect Phase 3 design decisions, and (2) extending `sharegrid-shared/src/protocol.ts` with the new message types and fields required by all three component repos.
>
> Complete all tasks in this plan before starting the router, host, or user implementation plans — they all depend on the updated shared protocol.

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
| 0 | Architecture document updates | 4 | — |
| 1 | Protocol additions | 6 | Phase 0 |

---

## Phase 0 — Architecture document updates

Update all four architecture documents to describe the Phase 3 design before any code is written. The architecture files are the source of truth; implementation plans and code must match them.

| # | Task | File | Status |
|---|------|------|:------:|
| S3-0 | Update `architecture_overview.md` §8 Phase 3 row: expand the one-line description to detail the router, host, and user changes. | `docs/architecture_overview.md` | `[x]` |
| S3-1 | Update `architecture_llmrouter.md`: change scope header to include Phase 3; extend §2.3 HostRegistry with `max_sessions`, `active_sessions`, computed `available_slots`/`total_slots`; extend §3.1 registration diagram with `context_size` and `max_sessions` in the payload; add §3.3 Host Status Update sequence diagram; update §8 Phase 3 row. | `docs/architecture_llmrouter.md` | `[x]` |
| S3-2 | Update `architecture_llmhost.md`: change scope header; extend §2.1 RouterClient (registration carries `maxSessions` + `contextSize`, heartbeat carries `activeSessions`, add `reportStatus()`); extend §2.2 SessionManager (capacity counter replaces binary slot, `slotId` threading, `onSessionCountChange` callback, `getActiveSessions()`); extend §2.3 InferenceProxy (`slotId` params, `id_slot` injection, per-slot DELETE); add `SHAREGRID_MAX_SESSIONS` to §2.5 config table; update §4 session lifecycle diagram; update §6 failure table entry for slot-full rejection; update §7 Phase 3 row. | `docs/architecture_llmhost.md` | `[x]` |
| S3-3 | Update `architecture_llmuser.md`: change scope header; extend §2.2 ModelRegistry (`resolveHosts()`, availability aggregation, `context_length`/`sharegrid_available_slots`/`sharegrid_total_slots` in model objects); extend §2.3 HostSessionPool (multi-session list per host, conversation-affinity acquire algorithm, `isInferenceActive()` description); update §2.5 API Server `POST /v1/chat/completions` to describe the `resolveHosts` + retry loop; update §6 Phase 3 row. | `docs/architecture_llmuser.md` | `[x]` |

---

## Phase 1 — Protocol additions

All changes are made once in the `sharegrid-shared` repository. After completion, update the git submodule pointer in `sharegrid-host`, `sharegrid-router`, and `sharegrid-user`.

The three submodule copies live at:
- `sharegrid-host/sharegrid-shared/`
- `sharegrid-router/sharegrid-shared/`
- `sharegrid-user/sharegrid-shared/`

Make all changes in the canonical shared repo (whichever is tracked by the submodules), then advance the submodule pointer in each consumer repo.

| # | Task | File | Status |
|---|------|------|:------:|
| S3-4 | **Fix pre-existing gap:** add `contextSize: number` to `RegistrationPayload`. The host already validates and uses `SHAREGRID_MODEL_CONTEXT_SIZE`; it was never included in the registration payload sent to the router, leaving `context_size` absent from the Host Registry and Host List despite being specified in the architecture. This fix closes that gap as part of Phase 3. | `sharegrid-shared/src/protocol.ts` | `[ ]` |
| S3-5 | Add `contextSize: number` to `HostListEntry`. The router will populate this from the value received at registration and include it in every host list response. LLMUsers surface it as `context_length` on `OpenAIModel`. | `sharegrid-shared/src/protocol.ts` | `[ ]` |
| S3-6 | Add `maxSessions: number` to `RegistrationPayload` (range 1–32, validated by the router) and `activeSessions: number` to `HeartbeatPayload` (current occupied slot count at the time of the heartbeat). | `sharegrid-shared/src/protocol.ts` | `[ ]` |
| S3-7 | Add new interface `HostStatusUpdate`: `{ v: ProtocolVersion; type: 'host_status_update'; hostId: string; activeSessions: number }`. Add `HostStatusUpdate` to the `RouterIncomingMessage` discriminated union. | `sharegrid-shared/src/protocol.ts` | `[ ]` |
| S3-8 | Add `availableSlots: number` and `totalSlots: number` to `HostListEntry`. The router computes these as `max_sessions - active_sessions` (clamped to 0) and `max_sessions` respectively. | `sharegrid-shared/src/protocol.ts` | `[ ]` |
| S3-9 | Update unit tests in `sharegrid-shared/tests/unit/protocol.test.ts`: add cases asserting that `HostStatusUpdate` is a valid member of `RouterIncomingMessage`; assert the new fields are present on `RegistrationPayload`, `HeartbeatPayload`, and `HostListEntry`. Advance the submodule pointer in `sharegrid-host`, `sharegrid-router`, and `sharegrid-user` to the commit that includes all protocol changes. Verify `npm run typecheck && npm run test:unit` passes in each consumer. | `sharegrid-shared/tests/unit/protocol.test.ts` + submodule pointers | `[ ]` |

---

## Completion ledger

| Phase | Status | Notes |
|-------|:------:|-------|
| 0 — Architecture updates | `[x]` | All four docs updated on `phase-3/plan` branch |
| 1 — Protocol additions | `[ ]` | |

---

## Next steps after completion

Proceed to `implementation_plan_llmrouter.md` (router and shared-protocol changes can be developed in parallel once Phase 1 of this plan is complete and the submodule pointers are updated).
