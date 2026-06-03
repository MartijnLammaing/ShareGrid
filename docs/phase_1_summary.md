# Phase 1 — MVP Completion Summary

> **Status: Complete.** 172 planned tasks across all three components are shipped and merged to `main`.

> **For agents:** The archived implementation plans linked at the [bottom of this file](#archived-implementation-plans)
> are historical task-level build records. **Do not open them during normal operation** — they contain no
> actionable information for future phases. Consult them only if explicitly instructed to investigate
> Phase 1 build history.

---

## Overview

Phase 1 is the ShareGrid MVP: a single router, a single host, and a single user communicating over
mutually-authenticated, fingerprint-pinned TLS. The network is CPU-only (llama.cpp), CLI-only, and
operates as a closed group where the router administrator distributes role-specific URLs out-of-band.

All Phase 1 work lives across four repositories plus the parent mono-repo:

| Repository | Role |
|---|---|
| `sharegrid-shared` | Shared wire-protocol types, crypto primitives, and TLS utilities |
| `sharegrid-router` | Network backbone: host registry, key authority, TLS listener |
| `sharegrid-host` | Compute provider: llama.cpp wrapper, session manager, router client |
| `sharegrid-user` | Consumer CLI: router handshake, host selection, prompt/response loop |
| `ShareGrid` (parent) | `start-dev.sh` development launcher; submodule wiring |

---

## Shared Library — `sharegrid-shared`

A zero-runtime-dependency TypeScript package consumed by all three components via `file:` path references.

**Wire protocol (`src/protocol.ts`)**
- `PROTOCOL_VERSION = 1` constant on every message — wire-breaking changes require a version bump
- Host↔Router messages: `RegistrationPayload` (includes `roleKey`), `RegistrationAck`, `HeartbeatPayload`, `HeartbeatAck`
- User↔Host messages: `SessionOpenPayload`, `SessionAck`, `SessionReject`, `PromptPayload`, `ResponseChunk`, `ResponseEnd`, `PromptCancel`, `PromptCancelled`, `SessionClose`, `SessionTimeout`
- User↔Router messages: `HostListRequest` (includes `roleKey`), `HostListResponse`, `HostListEntry`
- Token payload: `HostKeyTokenPayload` (`hostId`, `tlsFingerprint`, `expiresAt`)

**Crypto helpers (`src/crypto.ts`)**
- Ed25519 `signEd25519` / `verifyEd25519` using Node.js built-in `crypto` — no third-party crypto
- Host-key-token wire format: `encodeHostKeyToken` / `decodeHostKeyToken` (base64url payload + Ed25519 signature, dot-separated)

**TLS utilities (`src/tls.ts`)**
- `computeFingerprint(certPem)` — `sha256:<64 lowercase hex chars>` from DER bytes
- `parseFingerprintFromUrl(url)` — extracts `fp` (fingerprint) and `key` (role credential) from a ShareGrid URL; throws `RoleKeyMissingError` if `key` is absent
- `connectWithPinnedFingerprint(opts)` — opens a TLS connection and validates the peer cert fingerprint before resolving; fails closed on any mismatch

**Typed error classes (`src/errors.ts`)**
- `TlsFingerprintError` (`TLS_FINGERPRINT_MISMATCH`) — non-retryable; stops reconnect loop immediately
- `RoleKeyMissingError` (`ROLE_KEY_MISSING`) — non-retryable; thrown when a connection URL lacks the `key` param
- `HostBusyError`, `InvalidTokenError`, `NotRegisteredError`, `SlotEraseError`, `ProtocolVersionError`, `RegistrationRejectedError`, `HostNotFoundError`, `RouterStartupError`

---

## LLMRouter

A Node.js process running inside a Docker container. Acts as the network backbone for a ShareGrid group.

**TLS certificate management (`src/tls-cert-store.ts`)**
- Self-signed RSA-2048 cert generated on first startup, persisted to `/data/certs/` inside the container
- Subsequent startups reload the existing cert — fingerprint is stable across process restarts within the same container lifetime
- Each new container generates a fresh cert; both role URLs must be redistributed after a full container recreation

**Key Authority (`src/key-authority.ts`)**
- Ed25519 keypair generated in memory on startup — public key is distributed to hosts in `RegistrationAck`
- Two random role secrets generated on startup: `hostSecret` (embedded in host registration URLs) and `userSecret` (embedded in user access URLs)
- Issues signed `HostKeyTokenPayload` JWTs to hosts on registration and on each heartbeat acknowledgement; TTL = 2× heartbeat timeout

**Host Registry (`src/host-registry.ts`)**
- In-memory map of connected hosts keyed by `hostId`
- Each entry: `hostId`, `modelName`, `endpoint` (`host:port`), `tlsFingerprint`, `hostKeyToken`, `lastSeen`
- Background eviction loop runs every ⌊heartbeatTimeout / 3⌋ seconds; removes hosts whose `lastSeen` exceeds the configured timeout
- `list()` projects entries to `HostListEntry` wire shape (excludes `lastSeen`)

**TLS Listener (`src/tls-listener.ts`)**
- Single inbound TLS endpoint; demuxes connections on the first NDJSON message
- **Host registration path:** validates `roleKey` against `hostSecret` (fail-closed, no registry write on mismatch), validates payload shape, issues `RegistrationAck` with `hostKeyToken` and `routerPublicKey`, then enters heartbeat loop issuing fresh tokens on each `HeartbeatPayload`
- **User host-list path:** validates `roleKey` against `userSecret`, sends `HostListResponse` and immediately closes — router is not involved in session traffic
- 1 MiB per-message cap on all connections; malformed or oversized messages close the socket

**Startup banner (`src/startup-banner.ts`)**
- Printed to stdout after the TLS listener is ready
- Two labelled URL blocks: **HOST REGISTRATION URLs** (key = `hostSecret`) and **USER ACCESS URLs** (key = `userSecret`)
- Each URL carries `fp=sha256:<fingerprint>` and `key=<roleSecret>`; printed for all non-loopback IPv4 interfaces plus a best-effort public IP lookup
- `start-dev.sh` parses these URLs from `docker logs` to wire the host and user containers automatically

**Infrastructure**
- Zod-validated config: `SHAREGRID_LISTEN_ADDR`, `SHAREGRID_HEARTBEAT_TIMEOUT` (default 90 s)
- Pino structured logging with component tagging; JSON in production, pretty-printed in development
- Graceful shutdown: drains active connections with a 5 s cap on `SIGTERM` / `SIGINT`
- Dockerfile: two-stage build (Node.js builder → `node:22-slim` runtime); non-root `sharegrid` user; `/data/certs` writable
- Unit tests, integration tests, CI pipeline (GitHub Actions)

---

## LLMHost

A Node.js process running alongside llama.cpp inside a hardened Docker container.

**llama-server launcher (`src/llama-launcher.ts`)**
- Spawns `/app/llama-server` on container start; passes model path, Unix socket (`/tmp/llama.sock`), parallelism, and context size
- Polls for socket readiness with a 120 s timeout; exits the host process if llama-server exits unexpectedly

**Inference Proxy (`src/inference-proxy.ts`)**
- Forwards prompts to llama.cpp via `POST /v1/chat/completions` over the internal Unix socket using Node.js built-in `http`
- Parses SSE stream; calls `onChunk` for each `delta.content` fragment and `onEnd` on `[DONE]`
- `cancelPrompt()` destroys the in-flight request; `flushSlot()` calls `DELETE /slots/0` to erase the llama.cpp KV cache after session teardown (5 s timeout; host exits if erase fails)

**Session Manager (`src/session-manager.ts`)**
- TLS listener using the host's ephemeral cert; accepts exactly one session at a time
- On connection: validates `SessionOpenPayload.hostKeyToken` — checks Ed25519 signature, expiry, `hostId`, and TLS fingerprint match; rejects with `session_reject` if invalid or slot busy
- Forwards prompts to Inference Proxy; streams `ResponseChunk` / `ResponseEnd` back to the user
- Handles `PromptCancel` → calls `cancelPrompt()`, replies with `PromptCancelled`; session remains open
- Idle timeout; `SlotEraseError` causes `process.exit(1)` to force a clean container restart
- Tracks `registered` state: rejects new sessions when the router connection is lost

**Router Client (`src/router-client.ts`)**
- Generates an ephemeral RSA-2048 TLS keypair in memory on each startup
- Registers with the LLMRouter using the `SHAREGRID_ROUTER_URL` (which carries `fp`, `key`, and the router's IP and port); validates router cert fingerprint via pinned-connect
- On successful registration: receives `hostId`, initial `hostKeyToken`, and `routerPublicKey`; passes them to the Session Manager
- Heartbeat loop at configurable interval; rotates `hostKeyToken` on each `HeartbeatAck` (previous token kept valid for a 60 s overlap window)
- Exponential-backoff reconnect on disconnect: 1 s → 2 s → … → 60 s cap; stops immediately on `TlsFingerprintError` or `RoleKeyMissingError`

**Docker hardening**
- `--cap-drop ALL` — no Linux capabilities
- `--read-only` root filesystem; `/tmp` mounted as `tmpfs` (64 MiB, `noexec`, `nosuid`)
- `--ipc=none` — no shared memory with host
- `--security-opt no-new-privileges`
- `--restart=on-failure` — Docker restarts on unexpected exit
- No host networking; one TLS port published for user sessions; all llama.cpp traffic stays on `/tmp/llama.sock`

**Infrastructure**
- Zod-validated config: `SHAREGRID_ROUTER_URL` (validated `fp` + `key` params), `SHAREGRID_LISTEN_PORT`, `SHAREGRID_HEARTBEAT_INTERVAL` (default 30 s), `SHAREGRID_MODEL_FILE`, `SHAREGRID_MODEL_PATH`
- Pino structured logging with component tagging
- Graceful shutdown: 10 s drain for active sessions, then stops router client and session manager
- Dockerfile: three-stage build (llama.cpp builder → Node.js builder → `node:22-slim` runtime); `libgomp1` included for OpenMP; non-root `sharegrid` user; model baked in at build time via `--build-arg MODEL_FILE`
- Unit tests, integration tests, CI pipeline (GitHub Actions)

---

## LLMUser

A Node.js CLI running inside a Docker container (or directly on the user's machine).

**Router Client (`src/router-client.ts`)**
- Connects to the LLMRouter using `SHAREGRID_ROUTER_URL` with TLS fingerprint pinning and `roleKey` validation
- Sends `HostListRequest` (with `roleKey`); receives `HostListResponse` containing available hosts with their `endpoint`, `modelName`, `tlsFingerprint`, and `hostKeyToken`

**Session Client (`src/session-client.ts`)**
- Opens a direct TLS connection to the selected host using fingerprint pinning
- Sends `SessionOpenPayload` with the `hostKeyToken` received from the router
- Sends `PromptPayload`; receives and reassembles `ResponseChunk` stream until `ResponseEnd`
- Sends `PromptCancel` on Ctrl+C during generation; waits for `PromptCancelled` before returning control to the CLI (session remains open)
- Handles `SessionReject` with reason codes (`busy`, `invalid_token`, `not_registered`)

**CLI (`src/cli.ts`)**
- Presents numbered list of available hosts with model names after router handshake
- Readline-based prompt loop: user types a message, response streams to stdout character by character
- Ctrl+C during generation cancels the in-flight response; session stays open for the next prompt
- Ctrl+C at the input prompt (or EOF) exits the process cleanly
- All user-facing output via `process.stdout.write`; diagnostic logging via pino to `process.stderr`

**Infrastructure**
- Zod-validated config: `SHAREGRID_ROUTER_URL` (validated `fp` + `key` params)
- Dockerfile: two-stage build (Node.js builder → `node:22-slim` runtime); runs as non-root `sharegrid` user; interactive (`-it`) by design
- Unit tests, integration tests, CI pipeline (GitHub Actions)

---

## Development Tooling — `start-dev.sh`

A single script that builds and wires all three containers on one machine for local development and testing.

**What it does:**
1. Force-removes any existing `sharegrid-router` and `sharegrid-host` containers by name (handles running, stopped, and between-restart states — prevents stale-URL TLS fingerprint races on re-run)
2. Clears any other containers occupying ports 8443 or 9000
3. Creates the `sharegrid-net` Docker bridge network if it does not exist
4. Builds all three Docker images (skipped with `--no-build`)
5. Starts `sharegrid-router` as a detached container; polls `docker logs` for the startup banner and extracts the private-IP host registration URL and user access URL (up to 30 s)
6. Starts `sharegrid-host` with the extracted host registration URL; polls `docker logs` for `"registered with router"` (up to 60 s)
7. Becomes the `sharegrid-user` container via `exec docker run -it` — the user session is in the foreground; router and host keep running after exit

**Usage:**
```bash
./start-dev.sh            # build images and start
./start-dev.sh --no-build # skip image builds (use cached)
```

---

## Archived Implementation Plans

> **Agents: do not open the files linked below unless explicitly instructed.**
> They are historical task-level records of the Phase 1 build process and contain
> no actionable information for future phases. All relevant design decisions are
> captured in the architecture documents (`architecture_overview.md`,
> `architecture_llmrouter.md`, `architecture_llmhost.md`, `architecture_llmuser.md`).

| Component | Archived plan |
|-----------|--------------|
| LLMRouter | [`archived/phase_1/implementation_plan_llmrouter.md`](archived/phase_1/implementation_plan_llmrouter.md) |
| LLMHost | [`archived/phase_1/implementation_plan_llmhost.md`](archived/phase_1/implementation_plan_llmhost.md) |
| LLMUser | [`archived/phase_1/implementation_plan_llmuser.md`](archived/phase_1/implementation_plan_llmuser.md) |
