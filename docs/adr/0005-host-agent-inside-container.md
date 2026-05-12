# ADR-0005: Run All Host Agent Logic Inside the Docker Container

## Status

Accepted

## Date

2026-05-12

## Context

The previous architecture split the LLMHost into two distinct processes: a **Host Agent** running on the host OS (containing the Router Client, Session Manager, Inference Proxy, and Container Manager), and a **Docker container** running llama.cpp. The Host Agent managed the container's lifecycle and mediated all traffic between the LLMUser and llama.cpp.

This split introduced several complications:

- The Inference Proxy (outside the container) needed to reach llama.cpp (inside the container) via a Unix socket, requiring a bind-mounted directory — a deliberate exception to the no-volume-mount hardening rule (ADR-0004).
- The Container Manager was a non-trivial component responsible for image verification, container startup, health polling, and restart logic — all of which Docker itself can handle natively.
- Deployment required running two separate things on the host: the Host Agent process and the container.

**Alternative evaluated: everything inside the container**

Moving the Router Client, Session Manager, and Inference Proxy inside the container alongside llama.cpp:

- Eliminates the bind mount entirely — the Unix socket between the Inference Proxy and llama.cpp is internal to the container, requiring no volume mount.
- Eliminates the Container Manager — Docker's `--restart=on-failure` policy and `HEALTHCHECK` instruction replace its lifecycle management.
- Reduces the host-side to a single `docker run` command (or equivalent startup script). No separate Host Agent process is needed.
- The published port on the host maps directly to the Session Manager's TLS listener inside the container.

**TLS certificate management**

With the Session Manager inside the container, it generates an ephemeral TLS keypair at startup. The public cert fingerprint is sent to the LLMRouter as part of host registration. LLMUsers receive the fingerprint in the host list and pin to it when opening a TLS session. On container restart, a new keypair is generated and the host re-registers — consistent with the accepted re-registration behaviour.

**Re-registration identity**

Each container restart is treated as a new host. No persistent identity is maintained across restarts. The router accepts any valid re-registration. This simplifies the model: there is no persistent state on the host machine, and no mechanism is needed to prove continuity of identity.

**Impact on ADR-0004**

ADR-0004 decided to use a Unix socket via a bind-mounted directory to avoid exposing the llama.cpp management API on the Docker bridge. With the Inference Proxy now inside the container, the Unix socket is fully internal — no bind mount is needed. The trust boundary statement from ADR-0004 remains valid and is incorporated here.

## Decision

Move all Host Agent logic (Router Client, Session Manager, Inference Proxy) **inside the Docker container** alongside llama.cpp. The container is the single deployable unit. The host-side responsibility is reduced to running `docker run` with the correct hardening flags and digest-pinned image reference.

Implementation requirements:

- The container image includes the Router Client, Session Manager, Inference Proxy, and llama.cpp.
- The Session Manager's TLS listener port is the only port published to the host (`-p <host-port>:<container-port>`).
- The Unix socket between the Inference Proxy and llama.cpp is internal to the container — no volume mount is needed or used.
- The container is started with `--restart=on-failure` so Docker automatically restarts it on failure.
- The container includes a `HEALTHCHECK` instruction targeting llama.cpp's `GET /health` endpoint.
- On startup, the Router Client generates an ephemeral TLS keypair, connects to the LLMRouter, and registers with the cert fingerprint and model metadata.
- The host key and TLS private key are held in memory only. A container restart triggers full re-registration as a new host.
- No persistent state is written to the host filesystem. Each restart is a clean start.

## Trust boundary statement

This architecture, and all transport-layer decisions in this system, protect against **non-root host processes** that should not have access to the inference channel or session data.

They do not protect against a **malicious LLMHost operator**. Root on the host can read container process memory, attach a debugger via `ptrace`, or intercept traffic at the NIC level — regardless of what runs inside the container or how the internal transport is configured. Hardware-level isolation (TEE/SGX) would be required to close this gap, which is out of scope for all current phases.

**ShareGrid's trust model requires that LLMHost operators are trusted participants.** LLMUsers trust the host operator in the same way they trust a cloud provider — socially and contractually, not technically.

## Consequences

- **Good:** No bind mount required — the no-volume-mount hardening rule is now unconditional.
- **Good:** Container Manager is eliminated — Docker natively handles lifecycle, health, and restart.
- **Good:** Single deployable unit — the host operator runs one `docker run` command.
- **Good:** All internal communication (Inference Proxy ↔ llama.cpp) is inside the container with no host-visible surface.
- **Bad:** Container failure causes complete loss of the host (Session Manager, Router Client, and inference all go down together). In the previous design, the Host Agent could detect and restart the container while remaining reachable to the router. Now the host simply disappears from the router registry until Docker restarts it and it re-registers.
- **Neutral:** Each restart is a new host registration. LLMUsers holding a session token for the old instance are invalidated. This is accepted.
- **Neutral:** Supersedes ADR-0004 (Unix socket via bind mount). The Unix socket decision is retained but is now fully internal to the container.
