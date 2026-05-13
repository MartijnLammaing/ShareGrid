# ADR-0004: Unix socket for Inference Proxy ↔ Inference Server transport

## Status
Superseded by ADR-0005

## Date
2026-05-12

## Context
The Inference Proxy (on the host) needed to communicate with llama.cpp (inside the container). HTTP on the Docker bridge exposes the llama.cpp management API (including full session context via `GET /slots`) to any process on the host knowing the bridge IP/port. A Unix socket via bind mount limits access to the socket directory owner.

## Decision
Use a Unix domain socket via a dedicated `chmod 700` bind-mounted directory. The Host Agent verifies socket file ownership before connecting.

## Note
Superseded by ADR-0005, which moves all host agent logic inside the container. The Unix socket is retained but is now fully internal — the bind mount is no longer needed.
