# LLMHost — Implementation Plan

> **Scope:** Phase 1 (MVP). Companion to [`architecture_llmhost.md`](./architecture_llmhost.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the LLMHost build into small, agent-sized tasks and maintains a ledger of completion status.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** column. When an agent completes a task, update its status and the summary ledger at the bottom of this document.
3. Phases have prerequisites. Do not start Phase N+1 until Phase N is complete — later tasks assume the artefacts of earlier ones exist.
4. The Prerequisite phase (`sharegrid-shared`) lives in a separate repo but blocks all `sharegrid-host` work. Its tasks are listed here for visibility because the host module cannot type-check without them.

### Status legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete (merged to `main`, CI green) |
| `[!]` | Blocked — see notes |

---

## Phase overview

| Phase | Title | Tasks | Depends on |
|-------|-------|:-----:|------------|
| 0 | Prerequisite: `sharegrid-shared` | 8 | — |
| 1 | Repo scaffolding (`sharegrid-host`) | 6 | Phase 0 |
| 2 | Infrastructure modules (config, logger) | 3 | Phase 1 |
| 3A | Router Client | 6 | Phase 2 |
| 3B | Session Manager | 10 | Phase 2 |
| 3C | Inference Proxy | 4 | Phase 2 |
| 3D | Entry point orchestration | 2 | Phases 3A–3C |
| 4 | Dockerfile | 6 | Phase 3D |
| 5 | Unit tests | 5 | Phase 3D |
| 6 | Integration tests | 5 | Phase 3D |
| 7 | CI pipeline | 1 | Phase 5 |

---

## Phase 0 — Prerequisite: `sharegrid-shared`

These tasks live in the `sharegrid-shared` repository. They must be merged before any `sharegrid-host` task is attempted, because every component file imports from `@sharegrid/shared`.

| #     | Task                                                                                                                                                                                          | File / Location                | Status |
|-------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| S-1   | Initialise `sharegrid-shared` repo: `package.json` (name `@sharegrid/shared`, zero runtime dependencies), `tsconfig.json` (strict mode), `tsconfig.build.json` (excludes `tests/`), `.gitignore`. | repo root                     | `[x]`  |
| S-2   | Define all wire-protocol message interfaces and the `PROTOCOL_VERSION = 1` constant. Include: `RegistrationPayload`, `RegistrationAck`, `HeartbeatPayload`, `HeartbeatAck`, `SessionOpenPayload`, `SessionAck`, `SessionReject`, `PromptPayload`, `ResponseChunk`, `ResponseEnd`, `SessionClose`, `SessionTimeout`. Every interface includes `v: typeof PROTOCOL_VERSION` and a `type` discriminant. | `src/protocol.ts`              | `[x]`  |
| S-3   | Implement Ed25519 helpers using Node.js built-in `crypto`: `signEd25519(privateKey, payload): Buffer`, `verifyEd25519(publicKey, payload, signature): boolean`. Inputs are `Buffer`/`Uint8Array`; outputs are typed. No third-party crypto. | `src/crypto.ts`                | `[x]`  |
| S-4   | Implement TLS utilities: `parseFingerprintFromUrl(url): { host, port, fingerprint }` (extracts `fp=sha256:...` query param), `connectWithPinnedFingerprint(host, port, fingerprintHex): Promise<TLSSocket>` (rejects on mismatch, fails closed), `computeFingerprint(certPem): string` (returns `sha256:<hex>`). | `src/tls.ts`                   | `[x]`  |
| S-5   | Define typed error classes — each has a `readonly code` literal: `HostBusyError` (`"HOST_BUSY"`), `InvalidTokenError` (`"INVALID_TOKEN"`), `NotRegisteredError` (`"NOT_REGISTERED"`), `SlotEraseError` (`"SLOT_ERASE_FAILED"`), `ProtocolVersionError` (`"PROTOCOL_VERSION_MISMATCH"`), `TlsFingerprintError` (`"TLS_FINGERPRINT_MISMATCH"`). | `src/errors.ts`                | `[x]`  |
| S-6   | Write `index.ts` re-exporting everything from `protocol.ts`, `crypto.ts`, `tls.ts`, `errors.ts`. **Implementation note:** located at `src/index.ts` (not package root) so the TypeScript `rootDir` is consistent; `package.json#main` and subpath `exports` route consumers correctly. | `src/index.ts`                 | `[x]`  |
| S-7   | Unit-test `crypto.ts`: sign/verify round-trip succeeds; verify rejects tampered payload; verify rejects with wrong public key; verify rejects malformed signature.                            | `tests/unit/crypto.test.ts`    | `[x]`  |
| S-8   | Unit-test `tls.ts`: fingerprint parses correctly from URL; URL missing `fp` query param rejected; `computeFingerprint` produces stable SHA-256 over a known cert; pinned connection rejects mismatching fingerprint. | `tests/unit/tls.test.ts`       | `[x]`  |

---

## Phase 1 — Repo scaffolding (`sharegrid-host`)

| #    | Task                                                                                                                                                                                                                                                                                                                                | File / Location                | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| 1-1  | Initialise repo. `package.json` runtime deps: `@sharegrid/shared` (via `file:../sharegrid-shared`), `zod`, `pino`, `selfsigned`. Dev deps: `esbuild`, `tsx`, `vitest`, `eslint`, `@typescript-eslint/eslint-plugin`, `@typescript-eslint/parser`, `prettier`, `typescript`, `@types/node`, `pino-pretty`. Scripts per `implementation_guidelines.md` §8. | `package.json`                 | `[x]`  |
| 1-2  | Add `tsconfig.json` with `strict: true`, `target: ES2022`, `module: NodeNext`, `moduleResolution: NodeNext`, `noUncheckedIndexedAccess: true`. Add `tsconfig.build.json` extending it and excluding `tests/`.                                                                                                                                       | `tsconfig.json`, `tsconfig.build.json` | `[x]`  |
| 1-3  | Add ESLint config with `@typescript-eslint`. Enforce zero warnings. Disallow `any`. Disallow `console.log` in `src/` (except `console.error` in `config.ts`).                                                                                                                                                                                       | `.eslintrc.cjs`                | `[x]`  |
| 1-4  | Add Prettier config matching repo defaults (2-space indent, single quotes, trailing comma `all`, `printWidth: 100`).                                                                                                                                                                                                                                | `.prettierrc`                  | `[x]`  |
| 1-5  | Create empty source-file stubs (each exports a placeholder symbol so imports resolve during early development): `src/index.ts`, `src/config.ts`, `src/logger.ts`, `src/router-client.ts`, `src/session-manager.ts`, `src/inference-proxy.ts`.                                                                                                       | `src/*.ts`                     | `[x]`  |
| 1-6  | Create empty test directories with a placeholder `.gitkeep`: `tests/unit/`, `tests/integration/`.                                                                                                                                                                                                                                                   | `tests/`                       | `[x]`  |

---

## Phase 2 — Infrastructure modules

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | File                           | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| 2-1  | Implement `config.ts`. Zod schema fields: `SHAREGRID_ROUTER_URL` (string, must parse as URL, must contain `fp=sha256:[0-9a-f]+` query param), `SHAREGRID_LISTEN_PORT` (coerced int, 1–65535), `SHAREGRID_HEARTBEAT_INTERVAL` (coerced int, positive, default 30), `SHAREGRID_MODEL_NAME` (non-empty string), `SHAREGRID_MODEL_CONTEXT_SIZE` (coerced int, positive). Export `loadConfig(): Config`. On invalid input, write a structured error to `console.error` and call `process.exit(1)`. Do not read `process.env` anywhere else in the codebase. | `src/config.ts`                | `[x]`  |
| 2-2  | Implement `logger.ts`. Construct a root `pino` logger with JSON output (use `pino-pretty` transport when `NODE_ENV !== "production"`). Export `createComponentLogger(component: string): pino.Logger` returning a child logger with the `component` field bound. Levels per `implementation_guidelines.md` §10.                                                                                                                                                                                                                                                                                                                       | `src/logger.ts`                | `[x]`  |
| 2-3  | Unit-test `config.ts`. Cases: all required fields present + valid → returns parsed config with defaults applied; missing `SHAREGRID_ROUTER_URL` → exits with code 1; URL lacks `fp` query param → exits with code 1; port `0`, `65536`, non-numeric → exits with code 1; negative heartbeat → exits with code 1; default heartbeat = 30 when unset. Spy on `process.exit`.                                                                                                                                                              | `tests/unit/config.test.ts`    | `[x]`  |

---

## Phase 3A — Router Client

The Router Client owns the TLS connection to LLMRouter, manages the ephemeral keypair, performs registration, runs the heartbeat loop, and rotates host-key tokens.

| #    | Task                                                                                                                                                                                                                                                                                                                                                | File                              | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------|:------:|
| 3A-1 | Implement ephemeral TLS keypair generation using the `selfsigned` package. Generate a PEM cert + key on `start()`. Hold both in memory only. Expose `getTlsCert(): string`, `getTlsKey(): string`, `getTlsFingerprint(): string` (uses `@sharegrid/shared/tls.computeFingerprint`). Never write keys to disk.                                       | `src/router-client.ts`            | `[x]`  |
| 3A-2 | Implement the TLS connection to LLMRouter. Use `@sharegrid/shared/tls.parseFingerprintFromUrl` and `connectWithPinnedFingerprint`. On fingerprint mismatch, throw `TlsFingerprintError` — do not retry, do not fall back.                                                                                                                              | `src/router-client.ts`            | `[x]`  |
| 3A-3 | Implement registration. Send `RegistrationPayload` (with `v: PROTOCOL_VERSION`, `type: "register"`, model metadata from config, listen port from config, TLS cert fingerprint). Await `RegistrationAck`. Reject any message where `v !== PROTOCOL_VERSION`. Store `hostId`, `current_token` (from `hostKeyToken`), and the router's Ed25519 public key in memory. Invoke the `onRegistered` callback with `{hostId, currentToken, previousToken: null, routerPublicKey}`. | `src/router-client.ts`            | `[x]`  |
| 3A-4 | Implement the heartbeat loop. Every `SHAREGRID_HEARTBEAT_INTERVAL` seconds send `HeartbeatPayload`. On each `HeartbeatAck`, rotate tokens: `previous_token ← current_token`, `current_token ← ack.hostKeyToken`. Start a 60-second timer that clears `previous_token` when it fires (cancel and restart the timer on each rotation). Invoke `onTokenUpdate({currentToken, previousToken})` after every rotation. | `src/router-client.ts`            | `[x]`  |
| 3A-5 | Implement disconnection handling. On TLS connection loss: invoke `onDisconnect()` (Session Manager stops accepting new sessions); enter exponential backoff `1s → 2s → 4s → … capped at 60s`; on each attempt reconnect, re-register, and on success invoke `onRegistered` again. Reset backoff after a successful registration.                       | `src/router-client.ts`            | `[x]`  |
| 3A-6 | Export `createRouterClient(deps): RouterClient`. `deps` = `{ config, logger, onRegistered, onTokenUpdate, onDisconnect }`. `RouterClient` has `start(): Promise<void>` and `stop(): Promise<void>` (cancels timers, closes socket cleanly).                                                                                                          | `src/router-client.ts`            | `[x]`  |

---

## Phase 3B — Session Manager

The Session Manager is the TLS listener for LLMUser connections, validates host-key tokens, enforces the single session slot, and coordinates teardown.

| #     | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | File                              | Status |
|-------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------|:------:|
| 3B-1  | Implement the session slot. A synchronous binary lock with `acquire(): boolean` (returns `false` if already occupied), `release(): void`, `isOccupied(): boolean`. No async between check and acquire — must be a single synchronous transition.                                                                                                                                                                                                                            | `src/session-manager.ts`          | `[x]`  |
| 3B-2  | Implement the TLS server using `tls.createServer({cert, key})` with the ephemeral cert and key from the Router Client. Bind to `0.0.0.0:SHAREGRID_LISTEN_PORT`. Refuse new connections (immediate socket close) until `setRegistered(true)` has been called.                                                                                                                                                                                                                | `src/session-manager.ts`          | `[x]`  |
| 3B-3  | Implement newline-delimited JSON framing per connection. Buffer incoming bytes; emit a parsed JSON object each time `\n` is encountered. Reject (close the socket) any message where `v !== PROTOCOL_VERSION` or `type` is unknown. Refuse messages larger than 1 MiB (defensive cap; document the rationale inline).                                                                                                                                                       | `src/session-manager.ts`          | `[x]`  |
| 3B-4  | Implement `session_open` handling. Sequence: (1) if not registered → send `SessionReject` with `reason: "not_registered"`, close; (2) validate token (task 3B-5); on failure → send `SessionReject` `reason: "invalid_token"`, close; (3) attempt to acquire slot; if it fails → send `SessionReject` `reason: "busy"`, close; (4) on success → send `SessionAck` and continue to the prompt loop.                                                                            | `src/session-manager.ts`          | `[x]`  |
| 3B-5  | Implement three-step token validation as a pure function `validateToken(token, currentToken, previousToken, previousTokenExpiresAt, hostId, routerPublicKey, now): boolean`. Steps: (1) decode wire format (base64url payload + `.` + base64url signature); (2) verify Ed25519 signature against `routerPublicKey`; (3) parse payload JSON, check `hostId` matches; (4) verify token equals `currentToken` OR (equals `previousToken` AND `now < previousTokenExpiresAt`). All steps fail closed. | `src/session-manager.ts`          | `[x]`  |
| 3B-6  | Implement the idle timer. Start when the slot is acquired. Reset on each `PromptPayload` received. When 30 minutes elapse without a reset: send `SessionTimeout` to the user, then trigger teardown (task 3B-7).                                                                                                                                                                                                                                                              | `src/session-manager.ts`          | `[x]`  |
| 3B-7  | Implement session teardown. Sequence: (1) call `inferenceProxy.flushSlot()`; (2) on failure → `logger.error` + `process.exit(1)`; (3) on success → release the slot, clear the idle timer, close the TLS connection cleanly.                                                                                                                                                                                                                                                  | `src/session-manager.ts`          | `[x]`  |
| 3B-8  | Implement prompt/response forwarding. On `PromptPayload`: reset idle timer; call `inferenceProxy.sendPrompt(messages, onChunk, onEnd)`; pipe each `onChunk` as a `ResponseChunk` to the user; on `onEnd` send `ResponseEnd`. While a prompt is in flight, ignore subsequent `PromptPayload` messages from the user (close the connection — protocol violation).                                                                                                                | `src/session-manager.ts`          | `[x]`  |
| 3B-9  | Implement `SessionClose` handling from either side. On receipt: trigger teardown (task 3B-7). On the host-initiated path (e.g. idle timeout), send `SessionClose` to the user before closing the socket if the connection is still writable.                                                                                                                                                                                                                                  | `src/session-manager.ts`          | `[x]`  |
| 3B-10 | Export `createSessionManager(deps): SessionManager`. `deps` = `{ config, logger, inferenceProxy }`. `SessionManager` exposes `start(tlsCert, tlsKey): Promise<void>`, `stop(): Promise<void>`, `updateTokens({currentToken, previousToken, routerPublicKey, hostId}): void`, `setRegistered(flag: boolean): void`.                                                                                                                                                            | `src/session-manager.ts`          | `[x]`  |

---

## Phase 3C — Inference Proxy

The Inference Proxy is a thin forwarding layer between the Session Manager and llama.cpp over an internal Unix socket.

| #    | Task                                                                                                                                                                                                                                                                                                                          | File                              | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------|:------:|
| 3C-1 | Implement `sendPrompt(messages, onChunk, onEnd)`. Issue `POST /v1/chat/completions` to llama.cpp via Node.js `http.request` with `socketPath: '/tmp/llama.sock'`. JSON body: `{ model: config.modelName, messages, stream: true }`. Set `Content-Type: application/json`.                                                       | `src/inference-proxy.ts`          | `[x]`  |
| 3C-2 | Implement SSE stream parsing. Buffer the response body; on each `data: {...}\n\n` chunk, JSON-parse and extract `choices[0].delta.content`; invoke `onChunk(content)` per non-empty delta. On `data: [DONE]`, invoke `onEnd()`. On HTTP-level error or stream error, log and invoke `onEnd()` (the host treats it as completion). | `src/inference-proxy.ts`          | `[x]`  |
| 3C-3 | Implement `flushSlot(): Promise<boolean>`. Issue `DELETE /slots/0` to llama.cpp via the same Unix socket. Return `true` only on HTTP 2xx; return `false` on any error, timeout (5-second cap), or non-2xx status.                                                                                                              | `src/inference-proxy.ts`          | `[x]`  |
| 3C-4 | Export `createInferenceProxy(deps): InferenceProxy`. `deps` = `{ config, logger }`. `InferenceProxy` exposes `sendPrompt(messages, onChunk, onEnd): Promise<void>` and `flushSlot(): Promise<boolean>`.                                                                                                                        | `src/inference-proxy.ts`          | `[x]`  |

---

## Phase 3D — Entry point orchestration

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | File                  | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------|:------:|
| 3D-1 | Implement `src/index.ts`. Sequence: (1) `loadConfig()`; (2) construct logger; (3) `createInferenceProxy({config, logger})`; (4) `createSessionManager({config, logger, inferenceProxy})`; (5) `createRouterClient({config, logger, onRegistered, onTokenUpdate, onDisconnect})` where: `onRegistered` calls `sessionManager.updateTokens(...)` then `sessionManager.setRegistered(true)`; `onTokenUpdate` calls `sessionManager.updateTokens(...)`; `onDisconnect` calls `sessionManager.setRegistered(false)`. (6) `await sessionManager.start(routerClient.getTlsCert(), routerClient.getTlsKey())`; (7) `await routerClient.start()`. | `src/index.ts`        | `[x]`  |
| 3D-2 | Register `SIGTERM` / `SIGINT` handlers. On signal: `sessionManager.setRegistered(false)` (stop accepting new connections); wait for any active session to drain (max 10 s); call `routerClient.stop()` then `sessionManager.stop()`; `process.exit(0)`.                                                                                                                                                | `src/index.ts`        | `[x]`  |

---

## Phase 4 — Dockerfile

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | File                          | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 4-1  | Write **Stage 1** (llama.cpp builder). Base `debian:12-slim`. Install `build-essential`, `cmake`, `git`, `ca-certificates`. `git clone --depth 1 --branch b9371 https://github.com/ggml-org/llama.cpp /src/llama.cpp`. `cmake -S /src/llama.cpp -B /build -DLLAMA_CURL=OFF -DGGML_NATIVE=OFF -DGGML_CUDA=OFF -DGGML_METAL=OFF` then `cmake --build /build --target llama-server -j`. Copy the resulting `llama-server` binary to `/app/llama-server`.                                                  | `Dockerfile`                  | `[x]`  |
| 4-2  | Write **Stage 2** (Node.js builder). Base `node:22-slim`. `WORKDIR /app`. `COPY package.json package-lock.json ./`. `RUN npm ci`. `COPY src ./src`. `COPY tsconfig.json tsconfig.build.json ./`. `RUN npm run build`. Output: `/app/dist/bundle.cjs`.                                                                                                                                                                                                                                                              | `Dockerfile`                  | `[x]`  |
| 4-3  | Write **Stage 3** (runtime). Base `gcr.io/distroless/nodejs22-debian12`. Run `USER nonroot:nonroot` (the distroless image already provides a `nonroot` user). `COPY --from=stage1 /app/llama-server /app/llama-server`. `COPY --from=stage2 /app/dist/bundle.cjs /app/bundle.cjs`. Add a `HEALTHCHECK` targeting llama.cpp's `GET /health` over the Unix socket (use a tiny Node.js healthcheck script bundled into the image). `CMD ["/app/bundle.cjs"]`.                                                                                              | `Dockerfile`                  | `[x]`  |
| 4-4  | Add build-time `ENV` defaults in Stage 3 for `SHAREGRID_MODEL_NAME` and `SHAREGRID_MODEL_CONTEXT_SIZE`. These are placeholders intended to be overridden when building a model-specific image variant. Document the override mechanism in a header comment.                                                                                                                                                                                                                                                                                                | `Dockerfile`                  | `[x]`  |
| 4-5  | Add a seccomp profile JSON tuned to the syscalls llama.cpp + Node.js require (no `ptrace`, no `mount`, no `unshare`, no networking syscalls beyond what TLS needs). Document the operator's reference path (`--security-opt seccomp=/path/to/seccomp-profile.json`).                                                                                                                                                                                                                                                              | `seccomp-profile.json`        | `[x]`  |
| 4-6  | Write `docker-run.example.sh` documenting the full hardened invocation: digest-pinned image reference, `--cap-drop ALL`, `--read-only`, `--tmpfs /tmp`, `--no-new-privileges`, `--network <isolated bridge>`, `--ipc=none`, `--restart=on-failure`, `--security-opt seccomp=...`, `-p <host>:<container>`, and all required `-e` env vars.                                                                                                                                                                                                              | `docker-run.example.sh`       | `[x]`  |

---

## Phase 5 — Unit tests

| #    | Task                                                                                                                                                                                                                                                                                                                                                              | File                                       | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------|:------:|
| 5-1  | Unit-test `router-client.ts`. Cases: TLS fingerprint produced has `sha256:` prefix and 64-hex tail; registration payload contains all required fields with correct types; on `HeartbeatAck`, `current_token` becomes the new token and the old one moves to `previous_token`; `previous_token` is cleared after exactly 60 s (use `vi.useFakeTimers`); reconnect backoff sequence is `1 → 2 → 4 → 8 → 16 → 32 → 60 → 60 …`. | `tests/unit/router-client.test.ts`         | `[x]`  |
| 5-2  | Unit-test `session-manager.ts` token validation (`it.each` table). Cases: valid current-token → accepted; valid previous-token within 60 s window → accepted; previous-token past expiry → rejected; mismatched `hostId` → rejected; tampered signature → rejected; unknown token → rejected; missing `routerPublicKey` (not yet registered) → rejected.       | `tests/unit/session-manager.test.ts`       | `[x]`  |
| 5-3  | Unit-test `session-manager.ts` slot behaviour. Cases: first connection acquires slot; second connection while slot occupied receives `SessionReject reason: "busy"`; teardown releases the slot; teardown calls `inferenceProxy.flushSlot`; slot-erase failure triggers `process.exit(1)` (spy on `process.exit`).                                                | `tests/unit/session-manager.test.ts`       | `[x]`  |
| 5-4  | Unit-test `session-manager.ts` idle timer (`vi.useFakeTimers`). Cases: timer fires after 30 min of inactivity; each `PromptPayload` resets the timer; on expiry, `SessionTimeout` is sent and teardown runs.                                                                                                                                                       | `tests/unit/session-manager.test.ts`       | `[x]`  |
| 5-5  | Unit-test `inference-proxy.ts`. Mock `http.request` at the socket-path boundary. Cases: `sendPrompt` issues `POST /v1/chat/completions` with `stream: true`; SSE chunks become `onChunk` calls with the extracted `delta.content`; `data: [DONE]` invokes `onEnd`; `flushSlot` returns `true` on HTTP 200; `flushSlot` returns `false` on HTTP 500, timeout, or socket error. | `tests/unit/inference-proxy.test.ts`       | `[x]`  |

---

## Phase 6 — Integration tests

Integration tests use real TLS sockets and real timers. Mocks appear only at I/O boundaries that cannot be reasonably stood up (e.g. llama.cpp itself). The mock llama.cpp is a tiny Node.js HTTP server listening on a temporary Unix socket.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                | File                                   | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------|:------:|
| 6-1  | Integration test — happy path. Stand up mock llama.cpp + mock Router (real TLS) + real Session Manager + real Router Client + real Inference Proxy. From a TLS client: `session_open` with a valid token → expect `session_ack`; send a `prompt` → expect one or more `response_chunk`s + one `response_end`; send `session_close`. Verify the mock llama.cpp's `DELETE /slots/0` was called.        | `tests/integration/session.test.ts`    | `[x]`  |
| 6-2  | Integration test — slot busy. Open one valid session and leave it active. Open a second TLS connection and send `session_open`. Expect `session_reject` with `reason: "busy"`. Verify the first session is unaffected.                                                                                                                                                                              | `tests/integration/session.test.ts`    | `[x]`  |
| 6-3  | Integration test — slot erase failure. Configure mock llama.cpp to return HTTP 500 on `DELETE /slots/0`. Open and close a session. Verify `process.exit(1)` is called (spy on `process.exit`).                                                                                                                                                                                                       | `tests/integration/session.test.ts`    | `[x]`  |
| 6-4  | Integration test — router reconnect. Register successfully; abruptly close the router TLS connection. Verify Router Client enters backoff and Session Manager rejects new `session_open` attempts with `reason: "not_registered"`. Restart mock router; verify re-registration completes and new sessions are accepted again.                                                                       | `tests/integration/router-client.test.ts` | `[x]`  |
| 6-5  | Integration test — idle timeout. Open a session, send one prompt, then leave idle. Advance the fake clock by 30 minutes. Expect `session_timeout` on the client side, verify llama.cpp `DELETE /slots/0` was called, verify the slot is released and a subsequent connection succeeds.                                                                                                              | `tests/integration/session.test.ts`    | `[x]`  |

---

## Phase 7 — CI pipeline

| #    | Task                                                                                                                                                                                                                                                                                                                                              | File                          | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 7-1  | Add GitHub Actions workflow. Triggers: push to any branch, PRs targeting `main`. Steps in order: checkout, set up Node 22, `npm ci`, `npm run typecheck`, `npm run lint`, `npm run test:unit`. Run `npm run test:integration` only when the event is a PR targeting `main`. All gates must pass for the workflow to succeed.                       | `.github/workflows/ci.yml`    | `[ ]`  |

---

## Status ledger

Update this table whenever a task changes state. The phase rows are the source of truth; do not let the per-task tables and this ledger diverge.

| Phase | Title                                  | Total | Done | In progress | Blocked | Remaining |
|-------|----------------------------------------|:-----:|:----:|:-----------:|:-------:|:---------:|
| 0     | Prerequisite: `sharegrid-shared`       | 8     | 8    | 0           | 0       | 0         |
| 1     | Repo scaffolding (`sharegrid-host`)    | 6     | 6    | 0           | 0       | 0         |
| 2     | Infrastructure modules                 | 3     | 3    | 0           | 0       | 0         |
| 3A    | Router Client                          | 6     | 6    | 0           | 0       | 0         |
| 3B    | Session Manager                        | 10    | 10   | 0           | 0       | 0         |
| 3C    | Inference Proxy                        | 4     | 4    | 0           | 0       | 0         |
| 3D    | Entry point orchestration              | 2     | 2    | 0           | 0       | 0         |
| 4     | Dockerfile                             | 6     | 6    | 0           | 0       | 0         |
| 5     | Unit tests                             | 5     | 5    | 0           | 0       | 0         |
| 6     | Integration tests                      | 5     | 5    | 0           | 0       | 0         |
| 7     | CI pipeline                            | 1     | 0    | 0           | 0       | 1         |
| —     | **Total**                              | **56**| **55**| **0**      | **0**   | **1**     |

### Notes / blockers

- **Phase 1 complete.** `sharegrid-host` scaffolded at `../sharegrid-host` (commit `1e74e16`). `npm install` clean (engine warnings only — local Node v20.2.0; CI will use v22). `tsc --noEmit` passes with zero errors.
- **Phase 0 complete.** `sharegrid-shared` shipped as `@sharegrid/shared` v0.1.0 at <https://github.com/MartijnLammaing/sharegrid-shared> (commit `052ed3d`). Verification: `tsc --noEmit` clean, `vitest run tests/unit` → 39/39 passing, production build emits `.js` + `.d.ts` + source maps for all four modules.
- **S-5 implemented before S-4** because `tls.ts` imports `TlsFingerprintError`. Future plan revisions should reorder these.
- **`selfsigned`** is included in `sharegrid-shared` as a **dev**Dependency only (used by `tests/unit/tls.test.ts` to generate a real cert for pinned-connect tests). It is not in the runtime bundle, consistent with the zero-runtime-deps policy.

---

## Conventions reminder for implementers

- Source files: `kebab-case.ts`. Classes: `PascalCase`. Functions/variables: `camelCase`. (See `implementation_guidelines.md` §3.)
- Named exports only. No default exports.
- `async`/`await` only. No raw `.then()` chains.
- No `TODO` comments merged to `main` — open an issue instead.
- Conventional Commits with scope `host`: e.g. `feat(host): add router client heartbeat rotation`.
- One PR per task or per tightly related task cluster. CI must be green before merge.
