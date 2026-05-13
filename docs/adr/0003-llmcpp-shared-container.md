# ADR-0003: llama.cpp as inference server in a shared keep-alive container

## Status
Accepted

## Date
2026-05-12

## Context
Two decisions are coupled: which inference server to run, and whether the container is recreated per session or kept alive. Per-session containers incur 15–60 second startup latency and multiply memory cost by session count. Ollama conflicts with container hardening requirements; vLLM requires server-grade GPU; LocalAI adds unnecessary abstraction layers.

## Decision
Use llama.cpp server in a shared keep-alive container. Weights are loaded once at container start. Between sessions, the Inference Proxy calls `DELETE /slots/{id}` to clear the KV cache; the container restarts if the erase fails. Phase 1 runs with `--parallel 1` (single session slot).

## Consequences
- Good: No per-session startup latency; fixed memory cost regardless of session count.
- Bad: Session isolation is at the application layer. A llama.cpp slot bug could theoretically allow cross-session KV cache reads; container restart is the fallback mitigation.
