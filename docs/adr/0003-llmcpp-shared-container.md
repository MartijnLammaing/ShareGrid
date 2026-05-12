# ADR-0003: llama.cpp as Inference Server in a Shared Keep-Alive Container

## Status

Accepted

## Date

2026-05-12

## Context

Two decisions needed to be made together, since each determines the answer to the other:

1. **Which inference server to run inside the Docker container?**
2. **Should the container be shared across sessions (keep-alive) or created fresh per session?**

### Inference server candidates evaluated

**llama.cpp server** — a single compiled binary serving a REST API (`/v1/chat/completions`, OpenAI-compatible). Runs on consumer CPU or GPU. Uses GGUF model format. Minimal dependencies, small attack surface. Supports concurrent slots via `--parallel N` with per-slot KV cache isolation.

**Ollama** — popular developer tool with an OpenAI-compatible API. Designed as a user-facing system service with model management, internet-pull capabilities, and a persistent daemon. Most of these features conflict with the LLMHost's hardening requirements (no internet egress, read-only filesystem, digest-pinned image). Adds attack surface without adding inference capability over llama.cpp.

**vLLM** — high-throughput server using continuous batching and PagedAttention. Requires CUDA and server-grade GPU hardware. Overkill for Phase 1's single-session use case and misaligned with the consumer-hardware premise of ShareGrid.

**LocalAI** — a meta-server wrapping llama.cpp and other backends. Adds abstraction layers with no benefit for this use case; larger attack surface for the same underlying inference.

### Container lifetime candidates evaluated

**Per-session container** — the container is created when a session opens and destroyed when it ends. Provides OS-level memory isolation between sessions; the destroyed container carries no state forward.

- Startup latency of 15–60 seconds per session on consumer hardware (container creation + llama.cpp startup + model weight loading)
- In Phase 4 (multiple concurrent sessions), each container loads a full independent copy of the model weights — N sessions × model size in RAM, with no guaranteed page sharing across Docker container instances
- The startup cost and memory overhead were evaluated against the isolation benefit and judged to outweigh it given the existing application-layer isolation llama.cpp provides between slots

**Shared keep-alive container** — the container starts with the Host Agent and remains running. Sessions use it sequentially (Phase 1) or concurrently via slots (Phase 4). Between sessions, the slot's KV cache is explicitly cleared.

- No per-session startup latency
- Model weights loaded once; memory cost is fixed regardless of session count within the slot limit
- Isolation between sessions is at the application layer (llama.cpp slot boundaries) rather than OS level — accepted given that a software bug in slot management is judged a lower risk than the operational cost of per-session containers

## Decision

Use **llama.cpp server** in a **shared keep-alive container**.

- The container starts when the Host Agent starts and remains running until the Host Agent shuts down.
- Phase 1 configures llama.cpp with `--parallel 1` (single slot).
- Between sequential sessions, the Inference Proxy calls llama.cpp's `DELETE /slots/{id}` (or equivalent slot-erase endpoint) to explicitly clear the KV cache for that slot before the Session Manager releases the session lock.
- If the slot-erase call does not return success, the Container Manager restarts the container rather than risk state leakage into the next session.

### Phase 4 note

When Phase 4 introduces multiple concurrent sessions, `--parallel N` expands the slot count. Each concurrent session is assigned to a dedicated slot by the Session Manager; the slot assignment is tracked for the lifetime of that session. Slot-to-session mapping is a Phase 4 design concern and is not built into the Phase 1 Session Manager.

## Consequences

- **Good:** No per-session startup latency; users get a prompt CLI experience.
- **Good:** Memory cost is fixed at one model load regardless of session count within the configured slot limit.
- **Good:** llama.cpp's minimal footprint fits cleanly into the hardened container constraints.
- **Good:** The slot-erase mechanism is a concrete, testable reset step — the fallback (container restart) is deterministic.
- **Bad:** Session isolation is at the application layer, not OS level. A bug in llama.cpp's slot implementation could theoretically allow cross-session KV cache reads. This is accepted as a lower risk than the per-session container alternative's startup and memory costs.
- **Neutral:** Updating to a new model version requires updating the pinned digest (ADR-0002) and restarting the Host Agent, which causes a brief service interruption.
