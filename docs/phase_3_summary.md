# Phase 3 — Multi-Host Availability Completion Summary

> **Status: Complete.** 38 planned tasks across `sharegrid-shared`, LLMRouter, LLMHost, and LLMUser are shipped and merged to `main`.

> **For agents:** The archived implementation plans linked at the [bottom of this file](#archived-implementation-plans)
> are historical task-level build records. **Do not open them during normal operation** — they contain no
> actionable information for future phases. Consult them only if explicitly instructed to investigate
> Phase 3 build history.

---

## Overview

Phase 3 expands ShareGrid from a single-host/single-user MVP to a multi-host, multi-session network. The router
tracks per-host availability, hosts accept up to `maxSessions` concurrent sessions, and the user adapter routes
requests to available hosts with conversation affinity.

All Phase 3 work lives across four repositories plus the parent mono-repo:

| Repository | Final commit | Role |
|---|---|---|
| `sharegrid-shared` | `fbfc44a` | Protocol update: `availableSlots`, `totalSlots`, `contextSize` on `HostListEntry`; `activeSessions` in heartbeats and `host_status_update` |
| `sharegrid-router` | `157c05c` | Per-host slot tracking, `host_status_update` handling, availability-aware host list |
| `sharegrid-host` | `288b9cf` | Multi-session Session Manager, slot-ID-aware Inference Proxy, live load reporting |
| `sharegrid-user` | `c61cc9a` | Multi-session Host Session Pool with affinity, aggregated model slot metadata, retry loop in API Server |

---

## Shared Library — `sharegrid-shared`

Protocol update shared by router, host, and user (Phase 1 of the shared plan).

**Wire protocol (`src/protocol.ts`)**
- Extended `RegistrationPayload` with `contextSize` and `maxSessions`.
- Extended `HeartbeatPayload` with `activeSessions`.
- Added `HostStatusUpdate` for immediate load signalling outside the heartbeat cadence.
- Extended `HostListEntry` with `contextSize`, `availableSlots`, and `totalSlots`.
- `PROTOCOL_VERSION` remains `1` — additions are backward-compatible for Phase 3 consumers.

---

## LLMRouter

Network backbone. 8 tasks total.

**Registry (`src/registry.ts`)**
- Tracks `availableSlots` / `totalSlots` per host.
- Computes `availableSlots = maxSessions - activeSessions`, clamped to `0`.
- Exposes `updateHostStatus(hostId, activeSessions)` for immediate `host_status_update` messages.

**Host list response**
- Returns enriched `HostListEntry` objects so users can perform availability-aware selection.

**Tests** — unit + integration coverage for availability tracking and host-status updates.

---

## LLMHost

Compute provider inside the hardened Docker container. 12 tasks total.

**Session Manager (`src/session-manager.ts`)**
- Replaced single-session model with a slot counter supporting up to `maxSessions` concurrent sessions.
- Each accepted session is assigned a unique `id_slot`.
- Reports load on every session open/close via `host_status_update` and in every heartbeat.

**Inference Proxy (`src/inference-proxy.ts`)**
- Accepts a slot ID and injects `id_slot` into the request forwarded to llama.cpp.
- Per-slot KV-cache flush after each inference turn and on session end.

**Router Client (`src/router-client.ts`)**
- Sends `activeSessions` in heartbeats.
- Sends immediate `host_status_update` on session open/close.

**Tests** — unit + integration coverage for multi-session acceptance, slot-ID injection, and load reporting.

---

## LLMUser

Consumer interface (HTTP server + CLI). 17 tasks total.

**Session Client (`src/session-client.ts`)**
- Added `isInferenceActive()` so the pool can distinguish idle sessions from busy ones.

**Host Session Pool (`src/host-session-pool.ts`)**
- Changed internal map to `Map<string, SessionClient[]>`.
- `acquire()` implements conversation affinity: reuses an idle, alive session; opens a new one if all existing sessions are busy or dead.
- `closeAll()` closes every session in every list.

**Model Registry (`src/model-registry.ts`)**
- Extended `OpenAIModel` with `context_length`, `sharegrid_available_slots`, `sharegrid_total_slots`.
- Aggregates slot counts across hosts serving the same model name.
- Added `resolveHosts(modelId)` returning an available-first, stable-sorted host list.

**API Server (`src/api-server.ts`)**
- `POST /v1/chat/completions` now iterates the ordered host list from `resolveHosts()`.
- `HostBusyError` triggers a debug log and tries the next host.
- `TlsFingerprintError` invalidates the model cache and continues.
- Returns `503` when no host can be acquired.

**Tests** — 160 unit tests + 23 integration tests all green. Lint and typecheck clean.

---

## Parent Repository — `ShareGrid`

- Updated architecture documents to reflect Phase 3 design decisions (multi-host, availability tracking, network mode).
- Added Phase 3 implementation plans, then archived them on completion.
- Updated submodule pointers so `main` references the Phase 3 commits of all components.

---

## Archived Implementation Plans

> **Agents: do not open the files linked below unless explicitly instructed.**
> They are historical task-level records of the Phase 3 build process and contain
> no actionable information for future phases. All relevant design decisions are
> captured in the architecture documents (`architecture_overview.md`,
> `architecture_llmrouter.md`, `architecture_llmhost.md`, `architecture_llmuser.md`).

| Component | Archived plan |
|-----------|--------------|
| sharegrid-shared | [`archived/phase_3/implementation_plan_shared.md`](archived/phase_3/implementation_plan_shared.md) |
| LLMRouter | [`archived/phase_3/implementation_plan_llmrouter.md`](archived/phase_3/implementation_plan_llmrouter.md) |
| LLMHost | [`archived/phase_3/implementation_plan_llmhost.md`](archived/phase_3/implementation_plan_llmhost.md) |
| LLMUser | [`archived/phase_3/implementation_plan_llmuser.md`](archived/phase_3/implementation_plan_llmuser.md) |
