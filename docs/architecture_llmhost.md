# LLMHost — Component Architecture

> **Scope:** Phase 1 (MVP), Phase 2 (OpenCode provider + tool-call pass-through), and Phase 3 (concurrent sessions + availability reporting). See [`architecture_overview.md`](./architecture_overview.md) for system-wide context, security model, and the phase roadmap.

---

## 1. Responsibilities

The LLMHost has three distinct concerns that must be kept architecturally separate:

1. **Compute isolation** — run the LLM inside a hardened container so it cannot access the host machine.
2. **Network authority** — be the sole gatekeeper for who may open an inference session; enforce router-issued authentication.
3. **Session discipline** — accept exactly one session at a time; destroy all session state on teardown.

**Phase 2 addition:** the LLMHost becomes a transparent inference tunnel. The Inference Proxy forwards the full OpenAI request body (including tool definitions) verbatim to llama.cpp and streams raw SSE lines back to the LLMUser adapter. No parsing, no content extraction. Tool execution happens on the user machine, not here.

---

## 2. Internal Component Structure

The LLMHost is a single Docker container. All logic — router client, session management, inference proxying, and LLM inference — runs inside it. **Operators build their own image** with their chosen LLM (llama.cpp is the reference implementation and is used throughout this document; any inference engine satisfying the internal API contract may be substituted). Once the image is built, the host machine's only operational responsibility is starting the container with the correct hardening flags and registration URL.

```mermaid
graph TB
    subgraph Host Machine
        ST[docker run\nstartup script]

        subgraph Docker Container hardened
            RC[Router Client]
            SM[Session Manager]
            IP[Inference Proxy]
            LLM[llama.cpp]
        end
    end

    R([LLMRouter]) -- "TLS" --- RC
    U([LLMUser adapter]) -- "TLS" --- SM

    RC -- "host key + router\npublic key" --> SM
    SM --> IP
    IP -- "Unix socket\n(internal)" --> LLM
    ST -- "starts" --> RC
```

### 2.1 Router Client

Owns the connection to LLMRouter. Responsibilities:

- Generate an ephemeral TLS keypair at startup. The private key is held in memory only and is never written to disk.
- Parse the `fp`, `key` and `mode` query parameters from `SHAREGRID_ROUTER_URL`. `SHAREGRID_ROUTER_URL` must be the **host registration URL** (containing the host-specific `key`); it is distinct from the user access URL and cannot be used by LLMUsers. The `fp` value is a SHA-256 hex fingerprint prefixed with `sha256:` (e.g. `sha256:a3f1c2d4e5b6...`), matching the format printed by the router at startup (see [`architecture_llmrouter.md`](./architecture_llmrouter.md) §7). The `mode` value (`lan` default, or `internet`) is the **router's network mode**; the host advertises its session endpoint in the address family the mode dictates — IPv4 in `lan` mode, globally-routable IPv6 in `internet` mode. The host relays its IP address *according to the router's mode*; it does not select the family independently.
- Establish the TLS connection to the configured router address, pinned to the `fp` fingerprint.
- Send the registration payload: the host `key`, model name, context size, the Session Manager's listening port, the advertised `listenHost` (IPv4 in `lan` mode, IPv6 literal in `internet` mode), the TLS cert fingerprint, and `maxSessions` (from `SHAREGRID_MAX_SESSIONS`). The router validates the host `key` before admitting the registration, and composes the registry `endpoint` from `listenHost` + port — bracketing IPv6 literals (`[2001:db8::1]:9000`).
- Receive and store the router-issued **host key** (as `current_token`) and the **router's Ed25519 public key** in memory.
- Pass the current host key token and the router public key to the Session Manager once registration is confirmed.
- Emit a heartbeat on a fixed interval. Each heartbeat carries the current `activeSessions` count. Each heartbeat response carries a freshly issued host key token from the router; on receipt, rotate: `previous_token ← current_token`, `current_token ← new token`. Notify the Session Manager of the updated token pair. Clear `previous_token` after a 60-second grace period.
- **(Phase 3)** Expose a `reportStatus(activeSessions: number)` method. Called by the Session Manager immediately when a session slot is acquired or released; sends a `host_status_update` message to the router on the live connection. No-op if not yet registered or if the router socket is gone (the next heartbeat will reconcile the value).
- On router disconnection, attempt reconnection with exponential backoff (initial delay 1 s, doubling on each attempt, capped at 60 s) and signal the Session Manager to stop accepting new sessions until re-registration succeeds.

### 2.2 Session Manager

The single point of entry for incoming LLMUser connections. Responsibilities:

- **(Phase 1–2)** Maintain a **binary session slot** — a lock acquired when a session opens and released on teardown. **(Phase 3)** The binary slot is replaced by a **capacity counter**: a `Set<number>` of active slot IDs in the range `0..maxSessions-1`. `acquireSlot()` finds the lowest free ID, inserts it into the set, and returns it; `releaseSlot(slotId)` removes it. After every acquire or release, `onSessionCountChange(activeSessions)` is called — this triggers `RouterClient.reportStatus()` so the router's availability data is updated immediately.
- Validate the **host key** presented by the connecting LLMUser adapter against the current token pair (current + previous) before any inference traffic is allowed (see §5.2).
- Reject connections when: (a) no slot is available (set is full), (b) router registration is not confirmed, or (c) key validation fails.
- Enter an **inference loop** after session open: accept sequential `inference_request` messages, forward each to the Inference Proxy (passing the assigned `slotId`), stream `inference_response_chunk` messages back, and loop. The session remains open and the slot remains occupied between inference turns.
- Maintain an **idle timer** that resets each time an `inference_request` is received. If no request arrives within 30 minutes, the Session Manager closes the session and triggers normal teardown.
- Coordinate session teardown: instruct the Inference Proxy to flush the llama.cpp slot (by `slotId`), then release the session slot.
- On slot-erase failure, exit the container with a non-zero code — Docker's `--restart=on-failure` policy will restart it and trigger a clean re-registration.
- On TLS socket close/error during an active inference: abort the in-flight request (via `AbortSignal`), flush the llama.cpp slot (by `slotId`), release the session slot.
- Expose `getActiveSessions(): number` — returns the current set size; used by RouterClient for heartbeat reporting.

#### Session protocol (Phase 2)

The Session Manager exposes a raw **TLS server** using the ephemeral TLS keypair. The LLMUser ↔ LLMHost session uses newline-delimited JSON framing (see `implementation_guidelines.md` §6):

- On connection, the LLMUser adapter sends a `session_open` message carrying the host key token.
- The Session Manager responds with `session_ack` (accepted) or `session_reject` (slot occupied, invalid token, or router not registered).
- Once open, the session enters an **inference loop**:
  - The LLMUser adapter sends an `inference_request` message carrying the serialised OpenAI `/v1/chat/completions` request body (messages, tools, tool_choice, etc.) as a JSON string.
  - The Session Manager forwards the body to the Inference Proxy, which posts it verbatim to llama.cpp.
  - The Inference Proxy streams raw SSE lines back; each line is wrapped in an `inference_response_chunk` message and forwarded to the LLMUser adapter.
  - When the `data: [DONE]` SSE line is detected, the Inference Proxy signals completion. The KV cache is left intact so llama.cpp can reuse the cached prefix on the next turn. The Session Manager loops back to wait for the next `inference_request`.
- Either party may send `session_close` to end the session gracefully. The session slot is released and the KV cache is flushed if an inference was in progress.
- If the idle timer expires (no `inference_request` received for 30 minutes), the Session Manager sends `session_timeout` and closes the connection.

The session slot is tied to the **TLS connection**: acquired on `session_ack`, released when the connection closes.

### 2.3 Inference Proxy

A thin forwarding layer between the Session Manager and llama.cpp. Phase 2 design:

- **`forwardInference(body: string, onChunk: (sseLine: string) => void, signal: AbortSignal, slotId: number): Promise<void>`** — **(Phase 3)** injects `"id_slot": slotId` into the request body before posting to llama.cpp's `/v1/chat/completions` endpoint over the internal Unix socket. This directs llama.cpp to use the specific KV cache slot assigned to the session, enabling parallel inference across sessions without KV cache collisions. Emits each raw SSE line via `onChunk` (e.g. `"data: {...}"`, `"data: [DONE]"`). Resolves when `[DONE]` is emitted or when `signal` is aborted. No other content parsing; no text extraction; no tool-call awareness — this is a transparent pipe.
- **`flushSlot(slotId: number): Promise<boolean>`** — **(Phase 3)** calls llama.cpp's `DELETE /slots/<slotId>` to wipe the KV cache for the given slot. (Phase 1–2 used the hardcoded path `/slots/0`.) Called on session teardown (not between turns within the same session). Returns `false` on failure; the Session Manager exits the container on `false`.
- On `signal` abort: destroys the HTTP request to llama.cpp; calls `flushSlot(slotId)`.

The Inference Proxy uses Node.js's built-in `http.request` with `socketPath: '/tmp/llama.sock'`. This is the fixed internal path; it is not configurable at runtime.

> **Why raw pass-through rather than typed messages?**
> llama.cpp's OpenAI-compatible API already handles tool definitions, tool calls, and streaming natively. Passing the raw body through avoids the need to keep ShareGrid's protocol in sync with every OpenAI API feature (tool types, parallel tool calls, structured outputs, etc.). ShareGrid is a secure transport, not a content processor.

### 2.4 llama.cpp (Inference Server)

Runs the LLM model and serves the inference API. Configuration:

- `--unix-socket /tmp/llama.sock` — listens on an internal Unix socket only; no network port is opened for this channel.
- `--parallel 1` — single inference slot; enforces one active request at a time.
- **Tool calling** — llama.cpp's OpenAI-compatible API supports tool calling natively; Phase 2 requires no llama.cpp configuration change.
- **CPU-only in Docker** — no CUDA, Metal, or ROCm in the Linux container image.
- **Metal GPU on macOS** — **(Phase 4)** an Apple Silicon native deployment mode builds `llama-server` with `GGML_METAL=ON` and runs it under a restrictive `sandbox-exec` profile. The Node.js host code is unchanged; only the launch path differs.

### 2.5 Configuration

Configuration comes from two sources: values baked into the image at build time, and values supplied by the operator at `docker run` time.

#### Build-time configuration (Dockerfile ENV defaults)

| Variable | Description | Example |
|----------|-------------|---------|
| `SHAREGRID_MODELS_DIR` | Directory the host scans at startup. The first `.gguf` file (alphabetically) becomes the active model; its filename without the `.gguf` extension is the advertised model name. | `/data/models` |

#### Runtime configuration (docker run environment variables)

| Variable | Required | Description | Example |
|----------|:--------:|-------------|---------|
| `SHAREGRID_ROUTER_URL` | Yes | **Host registration URL** for this network. Contains the `fp` fingerprint, the host-specific `key`, and (in internet mode) `mode=internet`. | `https://192.168.1.10:8443?fp=sha256:a3f1...&key=h-x9k2mQ...` |
| `SHAREGRID_LISTEN_PORT` | Yes | Port the Session Manager TLS listener binds to inside the container. Must match the `-p` flag. | `9000` |
| `SHAREGRID_LISTEN_HOST` | Yes | This machine's address advertised to the router as the session endpoint users dial directly — its **LAN IPv4 address** in `lan` mode, or its **globally-routable IPv6 address** in `internet` mode (must match the router's mode). A bridge-networked container cannot detect the host address itself, so `docker-run.sh` detects it on the host OS and injects it. | `192.168.1.42` / `2001:db8::1` |
| `SHAREGRID_HEARTBEAT_INTERVAL` | No | Seconds between heartbeat pings to the router. Default: `30`. | `30` |
| `SHAREGRID_MAX_SESSIONS` | No | **(Phase 3)** Maximum number of concurrent user sessions. Passed as `--parallel <N>` to llama.cpp. Range 1–32. Default `1` (identical to Phase 1–2 behaviour). | `4` |
| `SHAREGRID_LLAMA_BINARY` | No | **(Phase 4)** Path to the `llama-server` binary. Default: `/app/llama-server`. Set by `docker-run.sh` and `macos-run.sh`. | `/app/llama-server` |
| `SHAREGRID_SANDBOX_PROFILE` | No | **(Phase 4)** Optional path to a `sandbox-exec` SBPL profile. When set, the inference process is launched inside `sandbox-exec`. Used by the macOS native launch script. | `macos-native/sandbox.sb` |

If any required runtime variable is absent, the container exits immediately with a clear error.

---

## 3. Startup Sequence

```mermaid
sequenceDiagram
    participant H as Host Operator
    participant D as Docker Daemon
    participant RC as Router Client (in container)
    participant SM as Session Manager (in container)
    participant LLM as llama.cpp (in container)
    participant R as LLMRouter

    H->>D: docker run (operator-built image,\nhardening flags, registration URL, --restart=on-failure)
    D->>RC: Start container processes
    RC->>RC: Generate ephemeral TLS keypair
    LLM->>LLM: Load model weights\nListen on internal Unix socket
    RC->>R: TLS connect + register\n(model name, port, TLS cert fingerprint, roleKey)
    R->>R: Add to host registry\nGenerate host key
    R-->>RC: Host key (Ed25519-signed token)\n+ router public key
    RC->>SM: Pass host key + router public key
    SM->>SM: Open session slot (accepting)
    Note over SM: LLMHost is now ready to accept sessions
```

---

## 4. Session Lifecycle (Phase 3)

Up to `maxSessions` connections may be open simultaneously; each acquires its own `slotId`. The diagram below shows a single session for clarity — multiple concurrent sessions follow the same pattern in parallel.

```mermaid
sequenceDiagram
    participant U as LLMUser adapter
    participant SM as Session Manager
    participant RC as Router Client
    participant IP as Inference Proxy
    participant LLM as llama.cpp

    U->>SM: Open TLS connection (pinned cert)\nPresent host key token
    SM->>SM: Validate host key (§5.2)
    SM->>SM: acquireSlot() → slotId (or null if full)

    alt key invalid or no slot available
        SM-->>U: session_reject
    else accepted
        SM->>RC: reportStatus(activeSessions)
        SM-->>U: session_ack

        loop Inference turns (one per OpenCode request/tool-result cycle)
            U->>SM: inference_request {body: "<OpenAI JSON>"}
            SM->>SM: Reset idle timer
            SM->>IP: forwardInference(body, signal, slotId)
            IP->>LLM: POST /v1/chat/completions (Unix socket)\nBody with id_slot injected
            loop SSE stream
                LLM-->>IP: SSE line
                IP-->>SM: onChunk(sseLine)
                SM-->>U: inference_response_chunk {data: sseLine}
            end
            LLM-->>IP: data: [DONE]
            IP-->>SM: Promise resolved
            Note over SM: KV cache intact for this slot — prefix reused on next turn<br/>Loop back — wait for next inference_request
        end

        alt User closes session
            U->>SM: session_close
        else Idle timeout (30 min no inference_request)
            SM->>SM: Idle timer expires
            SM-->>U: session_timeout
        else Socket closed by user (e.g. OpenCode exits)
            SM->>IP: abort in-flight inference
            IP->>LLM: request.destroy() + DELETE /slots/<slotId>
        end

        SM->>SM: releaseSlot(slotId)
        SM->>RC: reportStatus(activeSessions)
    end
```

---

## 5. Security Design

### 5.1 Host Key and TLS Key Storage

All keys are held **in process memory only**. Nothing is written to disk or to the host filesystem. Consequences:

- On container restart, the Router Client generates a new TLS keypair and re-registers as a new host. The previous host key and TLS cert are gone.
- Any LLMUser holding a token for the previous instance is automatically invalidated and must reconnect through the router.
- This is intentional: no stale credentials can persist across restarts, and no sensitive material is ever present on the host filesystem.

#### TLS certificate generation

The ephemeral self-signed TLS certificate is generated at process startup using the **`selfsigned`** npm package. Node.js has no built-in API for X.509 certificate generation; `selfsigned` wraps Node.js's own `crypto` primitives to produce a PEM-encoded cert and key without introducing any third-party cryptographic implementation. It is listed as a permitted runtime dependency in `implementation_guidelines.md` §13.

During normal operation, the Router Client holds two host key tokens in memory at all times: `current_token` (from the most recent heartbeat) and `previous_token` (from the heartbeat before that, retained for a 60-second grace period). Both are passed to the Session Manager and used for token validation. See §5.2.

The Router Client also receives and stores the **router's Ed25519 public key** during registration. This is used by the Session Manager to verify the signature on host keys presented by connecting LLMUser adapters. See [ADR-0001](./adr/0001-asymmetric-host-key-signing.md).

### 5.2 Session Key Validation

The LLMUser adapter presents the host key verbatim as received from the router. The token format is a dot-separated base64url-encoded payload and Ed25519 signature — see [`architecture_llmrouter.md`](./architecture_llmrouter.md) §4.2 for the full wire format specification. The Session Manager verifies it as follows:

1. **Signature check** — verify the Ed25519 signature using the router's public key. Any token failing this check is rejected immediately.
2. **Host match check** — the signed payload includes the host identifier. Tokens issued for a different host are rejected.
3. **Token freshness check** — the presented token must match either `current_token` or `previous_token` held by the Router Client. A match against `previous_token` is only accepted within the 60-second overlap window following the last heartbeat rotation. Any token matching neither is rejected.

All checks fail closed. No partial matches, no fallback paths. See [ADR-0001](./adr/0001-asymmetric-host-key-signing.md).

### 5.3 Docker Hardening Configuration

Hardening is split across two layers. The image enforces as much as possible so that a `docker run` with no hardening flags still has a reasonable baseline. The remaining constraints must be supplied by the operator at run time.

#### Dockerfile structure

The Dockerfile uses a **three-stage build**:

**Stage 1 — llama.cpp builder** — `debian:12-slim`; builds a CPU-only `llama-server` binary at a pinned git tag.

**Stage 2 — Node.js builder** — `node:22-slim`; runs `npm ci` and `npm run build` (esbuild) to produce `dist/bundle.cjs`.

**Stage 3 — runtime** — `node:22-slim`; copies only `/app/llama-server` and `/app/bundle.cjs`; installs `libgomp1` for OpenMP.

#### Image-level hardening (Dockerfile)

| Constraint | Mechanism |
|------------|-----------|
| Non-root user | `USER sharegrid:sharegrid` |
| Health check | `HEALTHCHECK` targeting llama.cpp `GET /health` over the Unix socket |
| Read-only compatible | Application writes nothing to the container filesystem at runtime; `/tmp` is the only exception, mounted as `tmpfs` at run time |

#### Runtime hardening (docker run flags)

| Flag | Purpose |
|------|---------|
| `--cap-drop ALL` | Drops all Linux capabilities |
| `--read-only` | Immutable container filesystem |
| `--tmpfs /tmp` | Writable temp directory for the llama.cpp Unix socket |
| `--no-new-privileges` | Processes cannot escalate privileges |
| `--network <isolated bridge>` | Container cannot see host network interfaces — this is why the host's advertised endpoint (LAN IPv4, or IPv6 in internet mode) must be injected via `SHAREGRID_LISTEN_HOST` rather than auto-detected. The Session Manager binds the IPv6 wildcard (`::`) in internet mode so IPv6 sessions are accepted |
| `--ipc=none` | No shared memory with host |
| `--restart=on-failure` | Docker automatically restarts on unexpected exit |
| `-p <host-port>:<container-port>` | Publishes only the Session Manager TLS port |

#### macOS native hardening (Phase 4)

On Apple Silicon, operators may run the host natively instead of inside Docker. The `macos-native/` directory contains:

- `setup.sh` — builds a Metal-enabled, statically-linked `llama-server` from the pinned `LLAMA_TAG`. `cmake` is a prerequisite; if it is not on `PATH`, `setup.sh` provisions one into a Python venv at `~/Library/Caches/sharegrid/cmake-venv` (override with `SHAREGRID_CMAKE_VENV`). This venv is kept **outside** the workspace so editor tooling does not auto-activate it and corrupt the stdin of TUI tools such as opencode.
- `sandbox.sb` — a restrictive SBPL profile parameterised with the binary path and models directory.
- `macos-run.sh` — launch script that sets the required environment, builds the host bundle if needed, and runs `node dist/bundle.cjs`.

The inference process is spawned inside `sandbox-exec`. The profile explicitly allows:

- execution of the configured `llama-server` binary,
- reading the model directory and the binary itself,
- reading system libraries/frameworks and the dyld cache,
- writing the Unix socket and Metal shader caches,
- Metal/IOKit services.

It explicitly denies:

- outbound and inbound network connections,
- reading sensitive host paths such as `/etc`.

`macos-run.sh` restarts the Node.js process on non-zero exit, mirroring Docker's `--restart=on-failure` behaviour.

> **Note:** `sandbox-exec` is deprecated by Apple and is intended as defense-in-depth, not as a sole security boundary. The operator is still a trusted participant in the ShareGrid network.

### 5.4 Session Isolation

The KV cache is flushed at **session teardown** — not between turns. This allows llama.cpp to reuse the cached prefix across turns within the same session: OpenAI-compatible clients (including OpenCode) always resend the full conversation history on every request, so llama.cpp's prefix matching only needs to process the new tokens rather than re-prefilling the entire context from scratch. This eliminates the dominant source of latency on large prompts.

Cross-session isolation is maintained by the slot lock: the slot is released only after `DELETE /slots/0` succeeds. A new user session can never acquire a slot whose KV cache still holds the previous user's context.

If the slot-erase call fails, the Session Manager exits the container with a non-zero code. Docker's `--restart=on-failure` policy restarts it and triggers clean re-registration.

### 5.5 Trust Boundary

The security measures in this document protect against **non-root host processes** and **external actors** who should not have access to the inference channel or session data.

They do not protect against a **malicious LLMHost operator** (root access to the host machine). They also do not allow the router or LLMUser adapters to **verify the contents of the Docker image** the operator is running.

**These two limitations are why ShareGrid is designed for closed groups of trusted actors, not open participation.** See [`architecture_overview.md`](./architecture_overview.md) §5.

---

## 6. Failure Handling

| Failure | Response |
|---------|----------|
| Router connection lost (no active session) | Router Client reconnects with exponential backoff (1 s → 60 s cap). Session slot remains closed until re-registration succeeds. |
| Router connection lost (during active session) | Active session is allowed to complete. New sessions are rejected until re-registration succeeds. |
| Container exits unexpectedly | Docker `--restart=on-failure` restarts it. Container re-registers as a new host. |
| Slot-erase fails after inference turn | Session Manager exits the container with a non-zero code. Docker restarts it. |
| Session slot occupied when new connection arrives | Immediate `session_reject`. No queue in Phase 1–2. **(Phase 3)** Rejected when `activeSlots.size === maxSessions`. |
| LLMUser idle for 30 minutes | Idle timer expires. Teardown: llama.cpp slot flushed, session lock released. User receives `session_timeout`. |
| LLMUser socket closes mid-inference | `AbortSignal` fires; Inference Proxy destroys the HTTP request; `flushSlot()` called; session lock released. |

---

## 7. Phase Roadmap — LLMHost Impact

| Phase | Change | What it means for LLMHost |
|-------|--------|---------------------------|
| **1** | MVP | Router Client, Session Manager (single prompt/response per turn), Inference Proxy (text extraction). |
| **2** | OpenCode provider integration | Inference Proxy redesigned as raw OpenAI pass-through. Session Manager updated to handle multi-turn inference loop on a persistent session. Phase 1 prompt/response/cancel protocol types removed from `sharegrid-shared`. |
| **3** | Multiple simultaneous sessions | Session Manager's binary slot becomes a capacity counter (`Set<number>` of slot IDs 0..maxSessions-1). `--parallel N` passed to llama.cpp from `SHAREGRID_MAX_SESSIONS`. InferenceProxy injects `id_slot` and uses per-slot `DELETE /slots/<id>`. RouterClient includes `activeSessions` in heartbeats and sends `host_status_update` on slot acquire/release. |
| **4** | macOS native deployment with Metal | The `llama-server` binary path and an optional `sandbox-exec` profile become runtime configuration. A new `macos-native/` directory builds a Metal-enabled `llama-server` and launches it under a restrictive SBPL sandbox on Apple Silicon. The Docker path remains unchanged and CPU-only. |
| **Future** | Cross-group resource accounting | Metering layer inside container; router-to-router peering. |
