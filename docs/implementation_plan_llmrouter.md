# LLMRouter — Implementation Plan

> **Scope:** Phase 1 (MVP). Companion to [`architecture_llmrouter.md`](./architecture_llmrouter.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the LLMRouter build into small, agent-sized tasks and maintains a ledger of completion status.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** column. When an agent completes a task, update its status and the summary ledger at the bottom of this document.
3. Phases have prerequisites. Do not start Phase N+1 until Phase N is complete — later tasks assume the artefacts of earlier ones exist.
4. The Prerequisite phase (`sharegrid-shared`) lives in a separate repo but blocks all `sharegrid-router` work. Its tasks are listed here for visibility because the router cannot type-check without them.

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
| 0 | Prerequisite: `sharegrid-shared` additions | 4 | — |
| 1 | Repo scaffolding (`sharegrid-router`) | 6 | Phase 0 |
| 2 | Infrastructure modules (config, logger, TLS cert store) | 4 | Phase 1 |
| 3A | Key Authority | 4 | Phase 2 |
| 3B | Host Registry | 5 | Phase 2 |
| 3C | TLS Listener | 8 | Phases 3A–3B |
| 3D | Entry point + startup banner | 3 | Phase 3C |
| 4 | Dockerfile | 4 | Phase 3D |
| 5 | Unit tests | 5 | Phase 3D |
| 6 | Integration tests | 5 | Phase 3D |
| 7 | CI pipeline | 1 | Phase 5 |

---

## Phase 0 — Prerequisite: `sharegrid-shared` additions

The LLMHost implementation plan defines the bulk of `sharegrid-shared` (tasks S-1 through S-8). The router needs four additional items in the same package. These must be merged before any `sharegrid-router` code can be written.

| #     | Task                                                                                                                                                                                                                                                                                                                                                                          | File / Location                  | Status |
|-------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------|:------:|
| S-9   | Add User ↔ Router protocol messages: `HostListRequest` (`type: "host_list_request"`) and `HostListResponse` (`type: "host_list_response"`, contains `hosts: HostListEntry[]`). Define `HostListEntry` interface with `hostId`, `modelName`, `contextSize`, `endpoint`, `tlsFingerprint`, `hostKeyToken`. Every interface includes `v: typeof PROTOCOL_VERSION`.                  | `src/protocol.ts`                | `[x]`  |
| S-10  | Add host-key-token wire-format helpers: `encodeHostKeyToken(payload: HostKeyTokenPayload, signature: Buffer): string` (returns `base64url(JSON.stringify(payload)) + "." + base64url(signature)`) and `decodeHostKeyToken(token: string): { payloadB64: string, payload: HostKeyTokenPayload, signature: Buffer }`. Define the `HostKeyTokenPayload` interface (`hostId`, `tlsFingerprint`, `expiresAt`). **Implementation note:** helpers live in `src/crypto.ts` (not a separate `token.ts` module); `HostKeyTokenPayload` is exported from `src/protocol.ts`. | `src/crypto.ts`                  | `[x]`  |
| S-11  | Add typed router-side error classes: `RegistrationRejectedError` (`"REGISTRATION_REJECTED"`), `HostNotFoundError` (`"HOST_NOT_FOUND"`), `RouterStartupError` (`"ROUTER_STARTUP_FAILED"`).                                                                                                                                                                                          | `src/errors.ts`                  | `[x]`  |
| S-12  | Unit-test the host-key-token wire format. Cases: encode→decode round-trip preserves payload and signature; decode rejects strings without exactly one `.`; decode rejects malformed base64url; signature is computed over the base64url-encoded payload string (matches `architecture_llmrouter.md` §4.2). **Implementation note:** tests live in `tests/unit/crypto.test.ts` (alongside the other crypto helpers), not a separate `token.test.ts`. | `tests/unit/crypto.test.ts`      | `[x]`  |

---

## Phase 1 — Repo scaffolding (`sharegrid-router`)

| #    | Task                                                                                                                                                                                                                                                                                       | File / Location                | Status |
|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| 1-1  | Initialise repo. `package.json` runtime deps: `@sharegrid/shared` (via `file:../sharegrid-shared`), `zod`, `pino`, `selfsigned`. Dev deps: `esbuild`, `tsx`, `vitest`, `eslint`, `@typescript-eslint/eslint-plugin`, `@typescript-eslint/parser`, `prettier`, `typescript`, `@types/node`, `pino-pretty`. Scripts per `implementation_guidelines.md` §8. | `package.json`                 | `[x]`  |
| 1-2  | Add `tsconfig.json` with `strict: true`, `target: ES2022`, `module: NodeNext`, `moduleResolution: NodeNext`, `noUncheckedIndexedAccess: true`. Add `tsconfig.build.json` extending it and excluding `tests/`.                                                                              | `tsconfig.json`, `tsconfig.build.json` | `[x]`  |
| 1-3  | Add ESLint config with `@typescript-eslint`. Enforce zero warnings. Disallow `any`. Disallow `console.log` in `src/` (except `console.error` in `config.ts` and `console.log` in the startup banner module).                                                                              | `.eslintrc.cjs`                | `[x]`  |
| 1-4  | Add Prettier config matching repo defaults (2-space indent, single quotes, trailing comma `all`, `printWidth: 100`).                                                                                                                                                                       | `.prettierrc`                  | `[x]`  |
| 1-5  | Create empty source-file stubs: `src/index.ts`, `src/config.ts`, `src/logger.ts`, `src/tls-cert-store.ts`, `src/key-authority.ts`, `src/host-registry.ts`, `src/tls-listener.ts`, `src/startup-banner.ts`.                                                                                  | `src/*.ts`                     | `[x]`  |
| 1-6  | Create empty test directories with `.gitkeep`: `tests/unit/`, `tests/integration/`.                                                                                                                                                                                                        | `tests/`                       | `[x]`  |

---

## Phase 2 — Infrastructure modules

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | File                                | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------|:------:|
| 2-1  | Implement `config.ts`. Zod schema fields: `SHAREGRID_LISTEN_ADDR` (string, must match `^.+:\d{1,5}$`), `SHAREGRID_HEARTBEAT_TIMEOUT` (coerced int, positive, default 90). Export `loadConfig(): Config`. On invalid input, write a structured error to `console.error` and call `process.exit(1)`. Expose parsed `host` and `port` properties separated from the raw string. Do not read `process.env` anywhere else in the codebase.                                                                                                                                                  | `src/config.ts`                     | `[x]`  |
| 2-2  | Implement `logger.ts`. Construct a root `pino` logger with JSON output (use `pino-pretty` transport when `NODE_ENV !== "production"`). Export `createComponentLogger(component: string): pino.Logger` returning a child logger with the `component` field bound. Levels per `implementation_guidelines.md` §10.                                                                                                                                                                                                                                                                          | `src/logger.ts`                     | `[x]`  |
| 2-3  | Implement `tls-cert-store.ts`. Manages the router's self-signed TLS cert at the fixed path `/data/certs/router.crt` + `/data/certs/router.key`. Functions: `loadOrGenerateCert(): { cert: string, key: string, fingerprint: string }` — if both files exist, read and return them; otherwise generate via `selfsigned` (RSA 2048 or Ed25519; document the choice), write to the fixed path with mode `0600`, then return. `fingerprint` is `sha256:<hex>` computed via `@sharegrid/shared/tls.computeFingerprint`. Create `/data/certs` directory if missing. Fail closed if the directory cannot be written. | `src/tls-cert-store.ts`             | `[x]`  |
| 2-4  | Unit-test `config.ts` and `tls-cert-store.ts`. Config cases: missing `SHAREGRID_LISTEN_ADDR` → exits; malformed `host:port` → exits; default timeout = 90; coerced numeric timeout. TLS cert store cases: first run generates cert files; second run loads existing files; fingerprint output has `sha256:` prefix. Use a temporary directory for the cert path in tests (override via internal helper, not env). | `tests/unit/config.test.ts`, `tests/unit/tls-cert-store.test.ts` | `[x]`  |

---

## Phase 3A — Key Authority

The Key Authority owns the router's Ed25519 signing key and issues signed host-key tokens.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                              | File                          | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 3A-1 | Generate an Ed25519 keypair on `start()` using Node.js built-in `crypto.generateKeyPairSync('ed25519')`. Hold both keys in memory only. Expose `getPublicKey(): string` (PEM-encoded SPKI) and a private accessor used only by the issuer logic.                                                                                                                                                  | `src/key-authority.ts`        | `[x]`  |
| 3A-2 | Implement `issueHostKeyToken(hostId, tlsFingerprint, ttlMs): string`. Compute `expiresAt = Date.now() + ttlMs`. Build the `HostKeyTokenPayload`. Use `@sharegrid/shared/token.encodeHostKeyToken` after signing the base64url payload string with the private key (via `@sharegrid/shared/crypto.signEd25519`). Token TTL must be set by the caller to `2 × heartbeatIntervalSeconds * 1000`. | `src/key-authority.ts`        | `[x]`  |
| 3A-3 | Reject issuance attempts with invalid inputs: empty `hostId`, missing `tlsFingerprint`, non-positive `ttlMs`. Throw a typed error (define `KeyAuthorityError` locally or extend `RegistrationRejectedError` from shared). Never write any state to disk.                                                                                                                                          | `src/key-authority.ts`        | `[x]`  |
| 3A-4 | Export `createKeyAuthority(deps): KeyAuthority`. `deps` = `{ logger }`. `KeyAuthority` exposes `getPublicKey()`, `issueHostKeyToken(hostId, tlsFingerprint, ttlMs)`. No `start`/`stop` required — the keypair is generated synchronously at construction.                                                                                                                                       | `src/key-authority.ts`        | `[x]`  |

---

## Phase 3B — Host Registry

The Host Registry is an in-memory map of active hosts with background eviction.

| #     | Task                                                                                                                                                                                                                                                                                                                                                          | File                            | Status |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------|:------:|
| 3B-1  | Define the `HostEntry` interface in `src/host-registry.ts` (not in shared — it is router-internal): `hostId`, `modelName`, `contextSize`, `endpoint`, `tlsFingerprint`, `hostKeyToken`, `lastSeen: number` (epoch ms).                                                                                                                                          | `src/host-registry.ts`          | `[x]`  |
| 3B-2  | Implement `add(entry: HostEntry): void` and `updateHeartbeat(hostId: string, newToken: string, now: number): boolean`. `updateHeartbeat` returns `false` if the host is unknown (caller treats this as a registration error). Both operations are synchronous and atomic with respect to JS event loop.                                                       | `src/host-registry.ts`          | `[x]`  |
| 3B-3  | Implement `list(): HostListEntry[]` returning all current entries projected to the wire-format `HostListEntry` shape (no `lastSeen` field — that is router-internal).                                                                                                                                                                                          | `src/host-registry.ts`          | `[x]`  |
| 3B-4  | Implement `evictStale(now: number): string[]`. Removes any entry whose `lastSeen` is older than `now - heartbeatTimeoutMs`. Returns the list of evicted `hostId`s for logging. Implement a background `setInterval` loop that calls `evictStale(Date.now())` every `heartbeatTimeoutMs / 3` (so eviction lag never exceeds one third of the timeout).            | `src/host-registry.ts`          | `[x]`  |
| 3B-5  | Export `createHostRegistry(deps): HostRegistry`. `deps` = `{ config, logger }`. `HostRegistry` exposes `add`, `updateHeartbeat`, `list`, `evictStale`, `start()` (begins the eviction loop), and `stop()` (clears the interval).                                                                                                                                  | `src/host-registry.ts`          | `[x]`  |

---

## Phase 3C — TLS Listener

The TLS Listener is the single inbound endpoint. It accepts both LLMHost and LLMUser connections, demuxes on the first message, and dispatches to the appropriate handler.

| #     | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | File                          | Status |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 3C-1  | Implement the TLS server using `tls.createServer({cert, key})` with the cert and key from `tls-cert-store`. Bind to `config.host:config.port`.                                                                                                                                                                                                                                                                | `src/tls-listener.ts`         | `[x]`  |
| 3C-2  | Implement newline-delimited JSON framing per connection: buffer incoming bytes; emit a parsed JSON object on each `\n`; reject (close the socket) any message where `v !== PROTOCOL_VERSION`; refuse messages larger than 1 MiB (defensive cap).                                                                                                                                                                | `src/tls-listener.ts`         | `[x]`  |
| 3C-3  | Implement connection demux. The first message determines the connection role: `type: "register"` → host registration handler; `type: "host_list_request"` → user handshake handler. Any other initial type → close the socket with no response.                                                                                                                                                              | `src/tls-listener.ts`         | `[x]`  |
| 3C-4  | Implement the host registration handler. Validate `RegistrationPayload` (modelName non-empty, contextSize positive, port 1–65535, tlsFingerprint matches `^sha256:[0-9a-f]{64}$`). Generate a new `hostId` (use `crypto.randomUUID()`). Compute the host endpoint: derive the remote IP from the TLS socket and combine with the host-supplied port. Issue a host-key token via Key Authority with `ttlMs = 2 * heartbeatTimeout * 1000`. Add a new entry to the Host Registry. Reply with `RegistrationAck` containing `hostId`, `hostKeyToken`, and `routerPublicKey`. | `src/tls-listener.ts`         | `[x]`  |
| 3C-5  | Implement the heartbeat handler (subsequent messages on a registered host connection). On `HeartbeatPayload`: verify the `hostId` matches the one issued to this connection; issue a fresh host-key token; call `hostRegistry.updateHeartbeat(hostId, newToken, now)`; reply with `HeartbeatAck { hostKeyToken: newToken }`. If the host is no longer in the registry (e.g. evicted during a long network pause), close the connection — the host will re-register.                                       | `src/tls-listener.ts`         | `[x]`  |
| 3C-6  | Implement the user handshake handler. On `HostListRequest`: call `hostRegistry.list()`; reply with `HostListResponse { hosts }`. After the reply, close the connection — the router is not involved further. No authentication of the user is performed in Phase 1.                                                                                                                                                | `src/tls-listener.ts`         | `[x]`  |
| 3C-7  | Implement per-connection lifecycle bookkeeping. On TLS socket close from a registered host: no registry change (the eviction loop handles inactivity). On socket error: log at `warn` level and close. Never throw out of socket event handlers.                                                                                                                                                                  | `src/tls-listener.ts`         | `[x]`  |
| 3C-8  | Export `createTlsListener(deps): TlsListener`. `deps` = `{ config, logger, tlsCert, tlsKey, keyAuthority, hostRegistry }`. `TlsListener` exposes `start(): Promise<void>` and `stop(): Promise<void>` (closes server, drains active connections with a 5-second cap).                                                                                                                                              | `src/tls-listener.ts`         | `[x]`  |

---

## Phase 3D — Entry point + startup banner

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | File                          | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 3D-1 | Implement `startup-banner.ts`. Function `printStartupBanner({listenAddr, fingerprint}): Promise<void>`. Enumerates non-loopback network interfaces via `os.networkInterfaces()`; attempts a public-IP lookup with a 2-second timeout against `https://api.ipify.org` (failure is non-fatal, log a warning); prints the multi-line banner from `architecture_llmrouter.md` §7 to `stdout` (via `console.log`, the only sanctioned use in `src/`). | `src/startup-banner.ts`       | `[x]`  |
| 3D-2 | Implement `src/index.ts`. Sequence: (1) `loadConfig()`; (2) construct logger; (3) `loadOrGenerateCert()`; (4) `createKeyAuthority({logger})`; (5) `createHostRegistry({config, logger})` and `hostRegistry.start()`; (6) `createTlsListener({config, logger, tlsCert, tlsKey, keyAuthority, hostRegistry})` and `tlsListener.start()`; (7) `printStartupBanner({listenAddr: config.SHAREGRID_LISTEN_ADDR, fingerprint})`. | `src/index.ts`                | `[x]`  |
| 3D-3 | Register `SIGTERM` / `SIGINT` handlers. On signal: call `tlsListener.stop()` (drains active connections), then `hostRegistry.stop()`, then `process.exit(0)`.                                                                                                                                                                                                                                                                                                                                                                       | `src/index.ts`                | `[x]`  |

---

## Phase 4 — Dockerfile

The router does not require the LLMHost's three-stage distroless build. A single-stage Node.js image is sufficient.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                          | File                          | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 4-1  | Write **Stage 1** (builder). Base `node:22-slim`. `WORKDIR /app`. `COPY package.json package-lock.json ./`. `RUN npm ci`. `COPY src ./src`. `COPY tsconfig.json tsconfig.build.json ./`. `RUN npm run build`. Output: `/app/dist/bundle.cjs`.                                                                                                                                                                                                                                                                  | `Dockerfile`                  | `[x]`  |
| 4-2  | Write **Stage 2** (runtime). Base `node:22-slim` (no distroless — operator may need `node` for debugging; router is trusted code). Create non-root `sharegrid` user/group. `WORKDIR /app`. `COPY --from=stage1 /app/dist/bundle.cjs /app/bundle.cjs`. `RUN mkdir -p /data/certs && chown sharegrid:sharegrid /data/certs && chmod 700 /data/certs`. `USER sharegrid`. `CMD ["node", "/app/bundle.cjs"]`. | `Dockerfile`                  | `[x]`  |
| 4-3  | Expose port `8443` (default) via `EXPOSE 8443`. Operators publish via `-p` as documented in `architecture_llmrouter.md` §6.1.                                                                                                                                                                                                                                                                | `Dockerfile`                  | `[x]`  |
| 4-4  | Write `docker-run.example.sh` showing the standard invocation: digest-pinned image, `-p 8443:8443`, `-e SHAREGRID_LISTEN_ADDR=0.0.0.0:8443`. Note that no volume mount is required and no hardening flags beyond default practice are needed.                                                                                                                                                  | `docker-run.example.sh`       | `[x]`  |

---

## Phase 5 — Unit tests

| #    | Task                                                                                                                                                                                                                                                                                                                                                  | File                                       | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------|:------:|
| 5-1  | Unit-test `key-authority.ts`. Cases: `getPublicKey()` returns a PEM-formatted SPKI string; `issueHostKeyToken` produces a token that round-trips through `decodeHostKeyToken` and verifies against the public key (`verifyEd25519`); invalid inputs (empty `hostId`, zero `ttlMs`) throw; the same `(hostId, fingerprint)` issued twice produces tokens that differ only in `expiresAt`. | `tests/unit/key-authority.test.ts`         | `[x]`  |
| 5-2  | Unit-test `host-registry.ts` (`it.each` for boundary cases). Cases: `add` then `list` returns the entry; `updateHeartbeat` updates `lastSeen` and replaces `hostKeyToken`; `updateHeartbeat` for unknown host returns `false`; `evictStale` removes hosts past the timeout and keeps hosts within it; boundary cases at exactly the timeout. Use `vi.useFakeTimers` for the eviction loop. | `tests/unit/host-registry.test.ts`         | `[x]`  |
| 5-3  | Unit-test `tls-listener.ts` demux and registration validation logic. Cases (mock the socket layer): `register` with valid payload triggers `keyAuthority.issueHostKeyToken` and `hostRegistry.add`, and replies with `RegistrationAck`; missing/invalid fields cause connection close with no registry write; `host_list_request` triggers `hostRegistry.list` and replies with `HostListResponse`; unknown first message closes the socket. | `tests/unit/tls-listener.test.ts`          | `[x]`  |
| 5-4  | Unit-test `tls-cert-store.ts`. Cases: cold start writes both files at mode 0600 and returns valid PEM + fingerprint; warm start reads existing files and returns the same fingerprint; unwritable directory throws.                                                                                                                                                  | `tests/unit/tls-cert-store.test.ts`        | `[x]`  |
| 5-5  | Unit-test `startup-banner.ts`. Cases: interfaces are enumerated and loopback addresses are excluded; banner output matches the §7 format; public-IP lookup timeout is handled gracefully (mock `fetch`/`https`); no interfaces found triggers the documented warning path.                                                                            | `tests/unit/startup-banner.test.ts`        | `[x]`  |

---

## Phase 6 — Integration tests

Integration tests use real TLS sockets and real timers.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                  | File                                    | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|:------:|
| 6-1  | Integration test — happy registration. Spin up a real router instance on an ephemeral port. From a TLS client (pinning the cert): send `RegistrationPayload`; expect `RegistrationAck` with valid `hostId`, a verifiable `hostKeyToken` (signature checks out against `routerPublicKey`), and a PEM public key.                                                                                          | `tests/integration/registration.test.ts`| `[x]`  |
| 6-2  | Integration test — heartbeat token rotation. Register a host; send a `HeartbeatPayload`; verify the `HeartbeatAck` contains a *new* `hostKeyToken` that also verifies; verify the Host Registry's `lastSeen` advanced.                                                                                                                                                                                  | `tests/integration/registration.test.ts`| `[x]`  |
| 6-3  | Integration test — host list returned to a user. Register two hosts (two separate TLS clients). From a third TLS client send `HostListRequest`; expect `HostListResponse` containing exactly two entries with all wire fields populated. Verify the user connection is closed by the router after the reply.                                                                                              | `tests/integration/host-list.test.ts`   | `[x]`  |
| 6-4  | Integration test — heartbeat timeout eviction. Configure `SHAREGRID_HEARTBEAT_TIMEOUT=3`. Register a host; stop sending heartbeats; advance fake time (or wait) past the timeout; from a user TLS client send `HostListRequest` and verify the evicted host is absent.                                                                                                                                  | `tests/integration/eviction.test.ts`    | `[x]`  |
| 6-5  | Integration test — TLS cert persistence. Start router; record the fingerprint from the startup banner. Stop and restart the router process (reuse the same cert directory). Verify the fingerprint is identical. Then delete the cert directory, restart, and verify the fingerprint differs.                                                                                                          | `tests/integration/tls-cert.test.ts`    | `[x]`  |

---

## Phase 7 — CI pipeline

| #    | Task                                                                                                                                                                                                                                                                                                                                               | File                          | Status |
|------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 7-1  | Add GitHub Actions workflow. Triggers: push to any branch, PRs targeting `main`. Steps in order: checkout, set up Node 22, `npm ci`, `npm run typecheck`, `npm run lint`, `npm run test:unit`. Run `npm run test:integration` only when the event is a PR targeting `main`. All gates must pass for the workflow to succeed.                       | `.github/workflows/ci.yml`    | `[ ]`  |

---

## Status ledger

Update this table whenever a task changes state. The phase rows are the source of truth; do not let the per-task tables and this ledger diverge.

| Phase | Title                                          | Total | Done | In progress | Blocked | Remaining |
|-------|------------------------------------------------|:-----:|:----:|:-----------:|:-------:|:---------:|
| 0     | Prerequisite: `sharegrid-shared` additions     | 4     | 4    | 0           | 0       | 0         |
| 1     | Repo scaffolding (`sharegrid-router`)          | 6     | 6    | 0           | 0       | 0         |
| 2     | Infrastructure modules                         | 4     | 4    | 0           | 0       | 0         |
| 3A    | Key Authority                                  | 4     | 4    | 0           | 0       | 0         |
| 3B    | Host Registry                                  | 5     | 5    | 0           | 0       | 0         |
| 3C    | TLS Listener                                   | 8     | 8    | 0           | 0       | 0         |
| 3D    | Entry point + startup banner                   | 3     | 3    | 0           | 0       | 0         |
| 4     | Dockerfile                             | 4     | 4    | 0           | 0       | 0         |
| 5     | Unit tests                             | 5     | 5    | 0           | 0       | 0         |
| 6     | Integration tests                      | 5     | 5    | 0           | 0       | 0         |
| 7     | CI pipeline                                    | 1     | 0    | 0           | 0       | 1         |
| —     | **Total**                                      | **49**| **48**| **0**      | **0**   | **1**     |

### Notes / blockers

- **Phase 1 complete.** `sharegrid-router` scaffolded at `../sharegrid-router` (commit `46dc705`). `npm install` clean (engine warnings only). `tsc --noEmit` passes with zero errors. Awaiting GitHub repo creation to push.
- **Phase 0 complete** as part of the LLMHost Phase 0 work. `sharegrid-shared` is published at <https://github.com/MartijnLammaing/sharegrid-shared> (commit `052ed3d`). All four router-specific shared items (S-9 through S-12) ship alongside the LLMHost items (S-1 through S-8) in the same package.
- **S-10:** host-key-token helpers landed in `src/crypto.ts` rather than a separate `src/token.ts` module — they sit naturally alongside `signEd25519` / `verifyEd25519` and the `base64url` helpers, with no other reuse case so far.
- **S-12:** tests for the token wire format live in `tests/unit/crypto.test.ts` (alongside the other crypto helpers) rather than a separate `token.test.ts`.

---

## Conventions reminder for implementers

- Source files: `kebab-case.ts`. Classes: `PascalCase`. Functions/variables: `camelCase`. (See `implementation_guidelines.md` §3.)
- Named exports only. No default exports.
- `async`/`await` only. No raw `.then()` chains.
- No `TODO` comments merged to `main` — open an issue instead.
- Conventional Commits with scope `router`: e.g. `feat(router): add host registry with heartbeat eviction`.
- One PR per task or per tightly related task cluster. CI must be green before merge.
