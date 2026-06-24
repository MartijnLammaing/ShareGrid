# Phase 3 — Active Task List

> This file tracks the current sub-phase's outstanding tasks. It is cleared when a sub-phase PR is merged and repopulated for the next sub-phase.
>
> Current sub-phase: **3.1 — Protocol (sharegrid-shared)**
> Branch: `phase-3/protocol` (to be created from `phase-3/plan`)

---

## Sub-phase 3.1 — sharegrid-shared protocol additions

See `implementation_plan_shared.md` Phase 1 for full task descriptions.

- [ ] S3-4 — Add `contextSize: number` to `RegistrationPayload` (pre-existing gap fix)
- [ ] S3-5 — Add `contextSize: number` to `HostListEntry`
- [ ] S3-6 — Add `maxSessions: number` to `RegistrationPayload`; add `activeSessions: number` to `HeartbeatPayload`
- [ ] S3-7 — Add `HostStatusUpdate` interface; add to `RouterIncomingMessage` union
- [ ] S3-8 — Add `availableSlots: number` and `totalSlots: number` to `HostListEntry`
- [ ] S3-9 — Update unit tests; advance submodule pointers in all three consumer repos

---

## Upcoming sub-phases (not started)

- **3.2 — Router** (`implementation_plan_llmrouter.md`): HostRegistry fields, TLS Listener registration/heartbeat/status-update handling
- **3.3 — Host** (`implementation_plan_llmhost.md`): Config, llama-launcher, InferenceProxy slot-ID, SessionManager capacity counter, RouterClient load reporting
- **3.4 — User** (`implementation_plan_llmuser.md`): SessionClient isInferenceActive, HostSessionPool multi-session, ModelRegistry resolveHosts, ApiServer retry loop
