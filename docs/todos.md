# Phase 3 — Active Task List

> Current sub-phase: **3.4 — User (LLMUser)**
> Top-level branch: `phase-3/protocol`

---

## Sub-phase 3.1 — sharegrid-shared — CLOSED ✅
## Sub-phase 3.2 — LLMRouter — CLOSED ✅
## Sub-phase 3.3 — LLMHost — CLOSED ✅

---

## Sub-phase 3.4 — LLMUser

See `implementation_plan_llmuser.md` for full task descriptions. All changes in `sharegrid-user` repo. Nested `sharegrid-shared` already at `fbfc44a`.

### Phase 0 — SessionClient: isInferenceActive()
- [ ] **U3-1** — Add `isInferenceActive(): boolean` to `SessionClient` interface; set flag in sendInferenceRequest/resolve/reject.
- [ ] **U3-2** — Update `tests/unit/session-client.test.ts`: false before, true during, false after resolve/reject.

### Phase 1 — HostSessionPool: multi-session with conversation affinity
- [ ] **U3-3** — Change internal map to `Map<string, SessionClient[]>`.
- [ ] **U3-4** — Rewrite `acquire()`: prune dead, find idle (conversation affinity), else open new.
- [ ] **U3-5** — Rewrite `closeAll()`: close all sessions in all lists.
- [ ] **U3-6** — Update `tests/unit/host-session-pool.test.ts`: affinity, dead pruning, HostBusyError propagation, closeAll.

### Phase 2 — ModelRegistry: availability-aware selection
- [ ] **U3-7** — Extend `OpenAIModel` with `context_length`, `sharegrid_available_slots`, `sharegrid_total_slots`.
- [ ] **U3-8** — Update `refresh()` to aggregate across hosts sharing same model name.
- [ ] **U3-9** — Add `resolveHosts(modelId): Promise<HostListEntry[]>` — available-first sorted.
- [ ] **U3-10** — Update `tests/unit/model-registry.test.ts`.

### Phase 3 — ApiServer: retry loop + slot metadata
- [ ] **U3-11** — Replace `resolveHost` with `resolveHosts` retry loop in `handleChatCompletions`; 503 on all-busy.
- [ ] **U3-12** — Verify `GET /v1/models` returns enriched objects (no handler change needed).
- [ ] **U3-13** — Update `tests/unit/api-server.test.ts`: retry, 503, cache invalidation, model list fields.

### Phase 4 — Integration tests
- [ ] **U3-14** — Update all `tests/integration/` mock HostListEntry objects with new fields.
- [ ] **U3-15** — Multi-host model routing: first host full → routes to second.
- [ ] **U3-16** — All-hosts-busy: both reject → 503.
- [ ] **U3-17** — Conversation affinity: two sequential requests → one session_open.

**Done when:** `npm run typecheck && npm run lint && npm run test:unit && npm run test:integration` green in `sharegrid-user`.
