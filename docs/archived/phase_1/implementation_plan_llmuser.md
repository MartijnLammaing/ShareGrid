# LLMUser — Implementation Plan

> **Scope:** Phase 1 (MVP). Companion to [`architecture_llmuser.md`](./architecture_llmuser.md) and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the LLMUser build into small, agent-sized tasks and maintains a ledger of completion status.

---

## How to use this document

1. Tasks are grouped into phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** column. When an agent completes a task, update its status and the summary ledger at the bottom of this document.
3. Phases have prerequisites. Do not start Phase N+1 until Phase N is complete — later tasks assume the artefacts of earlier ones exist.
4. `sharegrid-shared` is a hard prerequisite. The user module needs no new items from it — tasks S-1 through S-12 (defined in the host and router plans) cover everything required here.

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
| 0 | Prerequisite: `sharegrid-shared` | — | — |
| 1 | Repo scaffolding (`sharegrid-user`) | 6 | sharegrid-shared S-1–S-12 |
| 2 | Infrastructure modules (config, logger) | 3 | Phase 1 |
| 3A | Router Client | 4 | Phase 2 |
| 3B | Session Client | 7 | Phase 2 |
| 3C | CLI | 7 | Phase 2 |
| 3D | Entry point | 2 | Phases 3A–3C |
| 4 | Dockerfile | 3 | Phase 3D |
| 5 | Unit tests | 4 | Phase 3D |
| 6 | Integration tests | 5 | Phase 3D |
| 7 | CI pipeline | 1 | Phase 5 |
| 8 | Prompt cancellation (user side) | 4 | Phases 3B, 3C, host Phase 8 |
| 9 | Role-based access control (user access URL) | 4 | Phase 8 + router plan Phase 9 (S-13, S-14) |

---

## Phase 0 — Prerequisite: `sharegrid-shared`

**Status: complete.** `sharegrid-shared` v0.1.0 is published at <https://github.com/MartijnLammaing/sharegrid-shared> (commit `052ed3d`) and contains everything the LLMUser module needs:

- Host-list messages (`HostListRequest`, `HostListResponse`, `HostListEntry`) — task S-9 (router plan) `[x]`
- Session messages (`SessionOpenPayload`, `SessionAck`, `SessionReject`, `PromptPayload`, `ResponseChunk`, `ResponseEnd`, `SessionClose`, `SessionTimeout`) — task S-2 (host plan) `[x]`
- TLS fingerprint pinning utility (`connectWithPinnedFingerprint`) — task S-4 (host plan) `[x]`
- Typed errors (`HostBusyError`, `InvalidTokenError`, `NotRegisteredError`, `TlsFingerprintError`, `ProtocolVersionError`) — tasks S-5 and S-11 `[x]`
- Host-key-token wire format helpers (`decodeHostKeyToken`) — task S-10 (router plan) `[x]`

The LLMUser module itself introduced no new shared items.

---

## Phase 1 — Repo scaffolding (`sharegrid-user`)

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | File / Location                | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| 1-1  | Initialise repo. `package.json` runtime deps: `@sharegrid/shared` (via `file:../sharegrid-shared`), `zod`, `pino`. **No `selfsigned`** — the user never generates TLS certs. Dev deps: `esbuild`, `tsx`, `vitest`, `eslint`, `@typescript-eslint/eslint-plugin`, `@typescript-eslint/parser`, `prettier`, `typescript`, `@types/node`, `pino-pretty`. Scripts per `implementation_guidelines.md` §8.                                                                                  | `package.json`                 | `[x]`  |
| 1-2  | Add `tsconfig.json` with `strict: true`, `target: ES2022`, `module: NodeNext`, `moduleResolution: NodeNext`, `noUncheckedIndexedAccess: true`. Add `tsconfig.build.json` extending it and excluding `tests/`.                                                                                                                                                                                                                                                                       | `tsconfig.json`, `tsconfig.build.json` | `[x]`  |
| 1-3  | Add ESLint config with `@typescript-eslint`. Enforce zero warnings. Disallow `any`. Disallow `console.log` in `src/` (except `console.error` in `config.ts`). Add a `overrides` block for `src/cli.ts` that explicitly **allows** `process.stdout.write` and `process.stderr.write` — these are the sanctioned way to render user-facing CLI output (logger output via `pino` goes to a separate stream and is for diagnostics, not user UX).                                       | `.eslintrc.cjs`                | `[x]`  |
| 1-4  | Add Prettier config matching repo defaults (2-space indent, single quotes, trailing comma `all`, `printWidth: 100`).                                                                                                                                                                                                                                                                                                                                                              | `.prettierrc`                  | `[x]`  |
| 1-5  | Create empty source-file stubs (each exports a placeholder symbol so imports resolve during early development): `src/index.ts`, `src/config.ts`, `src/logger.ts`, `src/router-client.ts`, `src/session-client.ts`, `src/cli.ts`.                                                                                                                                                                                                                                                    | `src/*.ts`                     | `[x]`  |
| 1-6  | Create empty test directories with `.gitkeep`: `tests/unit/`, `tests/integration/`.                                                                                                                                                                                                                                                                                                                                                                                                | `tests/`                       | `[x]`  |

---

## Phase 2 — Infrastructure modules

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | File                           | Status |
|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------|:------:|
| 2-1  | Implement `config.ts`. Zod schema: `SHAREGRID_ROUTER_URL` (string, must parse as URL, must contain `fp=sha256:[0-9a-f]+` query param). Export `loadConfig(): Config`. On invalid input, write a structured error to `console.error` and call `process.exit(1)`. Do not read `process.env` anywhere else in the codebase.                                                                                                                                                                                                                                               | `src/config.ts`                | `[x]`  |
| 2-2  | Implement `logger.ts`. Construct a root `pino` logger writing to **`process.stderr`** (not stdout — stdout is reserved for CLI output). Use `pino-pretty` transport when `NODE_ENV !== "production"`. Export `createComponentLogger(component: string): pino.Logger` returning a child logger with the `component` field bound. Levels per `implementation_guidelines.md` §10.                                                                                                                                                          | `src/logger.ts`                | `[x]`  |
| 2-3  | Unit-test `config.ts`. Cases: required field missing → exits with code 1; URL malformed → exits with code 1; URL lacks `fp` query param → exits with code 1; valid URL parses correctly; `fp` value with wrong prefix (not `sha256:`) is rejected. Spy on `process.exit`.                                                                                                                                                                                                                                                                | `tests/unit/config.test.ts`    | `[x]`  |

---

## Phase 3A — Router Client

The Router Client opens a single TLS connection to LLMRouter, fetches the host list, and closes the connection.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | File                              | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------|:------:|
| 3A-1 | Implement the TLS connection. Use `@sharegrid/shared/tls.parseFingerprintFromUrl` to extract host, port, and fingerprint from `SHAREGRID_ROUTER_URL`. Use `connectWithPinnedFingerprint` to open the connection. On fingerprint mismatch, throw `TlsFingerprintError` — do not retry, do not fall back.                                                                                                                                                                                              | `src/router-client.ts`            | `[x]`  |
| 3A-2 | Implement newline-delimited JSON framing on the open socket: buffer incoming bytes; emit a parsed JSON object on each `\n`; reject (throw) any message where `v !== PROTOCOL_VERSION`; refuse messages larger than 1 MiB.                                                                                                                                                                                                                                                                            | `src/router-client.ts`            | `[x]`  |
| 3A-3 | Implement `fetchHostList(): Promise<HostListEntry[]>`. Sequence: open TLS connection (task 3A-1); send `HostListRequest` (`{v: PROTOCOL_VERSION, type: "host_list_request"}`); read exactly one `HostListResponse`; close the socket; return `response.hosts`. If the response `type` is wrong or fields are missing, throw a typed error.                                                                                                                                                          | `src/router-client.ts`            | `[x]`  |
| 3A-4 | Export `createRouterClient(deps): RouterClient`. `deps` = `{ config, logger }`. `RouterClient` exposes `fetchHostList(): Promise<HostListEntry[]>`. There is no `start`/`stop` — each call opens and closes its own connection.                                                                                                                                                                                                                                                                     | `src/router-client.ts`            | `[x]`  |

---

## Phase 3B — Session Client

The Session Client owns the direct TLS connection to a chosen LLMHost: presents the host-key token, sends prompts, and streams responses.

| #     | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | File                              | Status |
|-------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------|:------:|
| 3B-1  | Implement TLS connection to the chosen host. Inputs: `endpoint` (host:port) and `tlsFingerprint` from the `HostListEntry`. Use `@sharegrid/shared/tls.connectWithPinnedFingerprint` to enforce cert pinning. On fingerprint mismatch, throw `TlsFingerprintError` *before* sending the host-key token.                                                                                                                                                                                                | `src/session-client.ts`           | `[x]`  |
| 3B-2  | Implement newline-delimited JSON framing for the host connection (same constraints as 3A-2: 1 MiB cap, reject mismatched `v`).                                                                                                                                                                                                                                                                                                                                                                       | `src/session-client.ts`           | `[x]`  |
| 3B-3  | Implement the session-open handshake. Send `SessionOpenPayload` carrying the `hostKeyToken` from the selected `HostListEntry`. Wait for the first response. If `SessionAck` → transition to ready state. If `SessionReject` → throw the typed error mapped from `reason`: `"busy"` → `HostBusyError`, `"invalid_token"` → `InvalidTokenError`, `"not_registered"` → `NotRegisteredError`. Any other first message → close socket and throw `ProtocolVersionError` (or a similar typed error).        | `src/session-client.ts`           | `[x]`  |
| 3B-4  | Implement `sendPrompt(messages, onChunk, onEnd): Promise<void>`. Build `PromptPayload` (`v: PROTOCOL_VERSION`, `type: "prompt"`, `messages`). The caller (CLI) owns the conversation history and passes the **full** messages array on each call — the Session Client does not maintain history. Send the payload; resolve after the corresponding `ResponseEnd` is received. While the prompt is in flight, ignore any `PromptPayload`-like messages from the host (protocol violation).            | `src/session-client.ts`           | `[x]`  |
| 3B-5  | Implement response streaming. On `ResponseChunk` → call `onChunk(chunk.content)`. On `ResponseEnd` → call `onEnd()` and resolve the in-flight `sendPrompt` promise. Maintain a flag so chunks received outside an in-flight prompt are treated as a protocol error.                                                                                                                                                                                                                                     | `src/session-client.ts`           | `[x]`  |
| 3B-6  | Handle host-initiated termination. On `SessionTimeout` → reject any in-flight `sendPrompt` with `SessionTimeoutError` (define this typed error locally in `session-client.ts` if not provided by `@sharegrid/shared`) and close the socket. On `SessionClose` → resolve any in-flight `sendPrompt` with an end-of-stream indication and close the socket. On unexpected socket close → reject in-flight calls with a generic connection error.                                                          | `src/session-client.ts`           | `[x]`  |
| 3B-7  | Export `createSessionClient(deps): SessionClient`. `deps` = `{ logger }`. `SessionClient` exposes `openSession(host: HostListEntry): Promise<void>`, `sendPrompt(messages, onChunk, onEnd): Promise<void>`, and `closeSession(): Promise<void>` (sends `SessionClose`, then closes the socket). Throws if `sendPrompt` is called before `openSession` succeeds.                                                                                                                                          | `src/session-client.ts`           | `[x]`  |

---

## Phase 3C — CLI

The CLI is the user-facing interface. It uses Node.js's built-in `readline` for input and writes to `process.stdout` for output. No external CLI framework dependency.

| #     | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | File                          | Status |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 3C-1  | Implement host-list rendering. Function `renderHostList(hosts: HostListEntry[]): void` writes a numbered list to `process.stdout`: index, model name, context size, endpoint. If the list is empty, write a clear message and return — the caller will exit.                                                                                                                                                                                                                                       | `src/cli.ts`                  | `[x]`  |
| 3C-2  | Implement host selection. Function `promptHostSelection(hosts): Promise<HostListEntry>` uses Node.js's built-in `readline` to read a 1-based index. Reprompt on invalid input (non-numeric, out of range, blank). Pressing Ctrl+C during selection terminates the process cleanly.                                                                                                                                                                                                                  | `src/cli.ts`                  | `[x]`  |
| 3C-3  | Implement the conversation loop. Maintain a `messages: Array<{role: "user" \| "assistant", content: string}>` array in memory. On each turn: read a line of user input via `readline`; append `{role: "user", content: input}`; call `sessionClient.sendPrompt(messages, onChunk, onEnd)`; accumulate the streamed response into a string while writing chunks to `process.stdout.write()`; on `onEnd` write a trailing newline and append `{role: "assistant", content: accumulated}` to history.        | `src/cli.ts`                  | `[x]`  |
| 3C-4  | Implement error handling around the conversation loop. Distinct user-facing messages and actions per error: `HostBusyError` → display "host is busy" and offer to re-select from the cached list; `InvalidTokenError` → display "session token expired" and offer to re-fetch the host list; `SessionTimeoutError` → display "session timed out" and offer to re-select; `TlsFingerprintError` → display "host cert mismatch" and offer to re-select; network errors → display and offer to re-select. | `src/cli.ts`                  | `[x]`  |
| 3C-5  | Implement re-select / re-fetch helpers. `reselect(hosts)` re-runs `promptHostSelection` against the cached list; `refetch(routerClient)` calls `routerClient.fetchHostList()` again and then re-runs host selection. Both paths clear the in-memory conversation history (new session, new context).                                                                                                                                                                                                | `src/cli.ts`                  | `[x]`  |
| 3C-6  | Implement SIGINT (Ctrl+C) handling inside the CLI. If a session is active: call `sessionClient.closeSession()` first; then exit with code 0. If no session is active: exit immediately with code 0. Print a goodbye line to `process.stdout` before exit.                                                                                                                                                                                                                                            | `src/cli.ts`                  | `[x]`  |
| 3C-7  | Export `createCli(deps): Cli`. `deps` = `{ routerClient, sessionClient, logger }`. `Cli` exposes `run(): Promise<void>` which: fetches host list, displays it, accepts selection, opens session, runs the conversation loop, handles errors and re-selection until the user exits.                                                                                                                                                                                                                  | `src/cli.ts`                  | `[x]`  |

---

## Phase 3D — Entry point

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | File                          | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 3D-1 | Implement `src/index.ts`. Sequence: (1) `loadConfig()`; (2) construct logger; (3) `createRouterClient({config, logger})`; (4) `createSessionClient({logger})`; (5) `createCli({routerClient, sessionClient, logger})`; (6) `await cli.run()`. On unexpected exceptions bubbling out of `cli.run()`, log and exit with code 1.                                                                                                                                                                                                                  | `src/index.ts`                | `[x]`  |
| 3D-2 | Register a `SIGTERM` handler at the entry point (the CLI handles `SIGINT` itself per task 3C-6). On `SIGTERM`: best-effort close any active session, then `process.exit(0)`.                                                                                                                                                                                                                                                                                                                                                                  | `src/index.ts`                | `[x]`  |

---

## Phase 4 — Dockerfile

The user is a CLI. Docker packaging is provided for parity with the host and router; the typical operator workflow is to run the CLI on a developer machine, not in a container. The Dockerfile is a multi-stage Node build with no special hardening.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                       | File                          | Status |
|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 4-1  | Write **Stage 1** (builder). Base `node:22-slim`. `WORKDIR /app`. `COPY package.json package-lock.json ./`. `RUN npm ci`. `COPY src ./src`. `COPY tsconfig.json tsconfig.build.json ./`. `RUN npm run build`. Output: `/app/dist/bundle.cjs`.                                                                                                                                              | `Dockerfile`                  | `[x]`  |
| 4-2  | Write **Stage 2** (runtime). Base `node:22-slim`. Create non-root `sharegrid` user/group. `WORKDIR /app`. `COPY --from=stage1 /app/dist/bundle.cjs /app/bundle.cjs`. `USER sharegrid`. `CMD ["node", "/app/bundle.cjs"]`. Note: the CLI requires a TTY — image must be run with `docker run -it`.                                                                                            | `Dockerfile`                  | `[x]`  |
| 4-3  | Write `docker-run.example.sh`: `docker run -it --rm -e SHAREGRID_ROUTER_URL=https://...?fp=sha256:... registry/llmuser@sha256:<digest>`. Document the `-it` flag requirement inline.                                                                                                                                                                                                       | `docker-run.example.sh`       | `[x]`  |

---

## Phase 5 — Unit tests

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                | File                                       | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------|:------:|
| 5-1  | Unit-test `router-client.ts`. Cases (mock the TLS socket layer): `fetchHostList` sends `HostListRequest` with correct shape; parses a valid `HostListResponse` and returns its `hosts`; rejects responses with wrong `type`; rejects responses with `v !== PROTOCOL_VERSION`; closes the socket after the response is received; TLS fingerprint mismatch propagates as `TlsFingerprintError`. | `tests/unit/router-client.test.ts`         | `[x]`  |
| 5-2  | Unit-test `session-client.ts` (handshake). Cases: `session_ack` resolves `openSession`; each `session_reject` reason maps to the right typed error (`it.each` table); TLS fingerprint mismatch throws before any payload is sent; unexpected first message (e.g. a `response_chunk` before `session_ack`) throws.                                                                                                                       | `tests/unit/session-client.test.ts`        | `[x]`  |
| 5-3  | Unit-test `session-client.ts` (prompt/response). Cases: `sendPrompt` sends `PromptPayload` with the full messages array passed in by the caller; `response_chunk`s invoke `onChunk` with `content`; `response_end` invokes `onEnd` and resolves `sendPrompt`; `session_timeout` rejects in-flight `sendPrompt` with `SessionTimeoutError`; unexpected socket close rejects in-flight calls.                                              | `tests/unit/session-client.test.ts`        | `[x]`  |
| 5-4  | Unit-test `cli.ts`. Cases (mock `readline`, capture `process.stdout.write` via a spy): host list renders all entries with correct numbering; empty host list prints the documented message and exits; invalid selection reprompts; conversation history grows correctly across turns; each error type prints its mapped message and triggers the correct next action (re-select vs re-fetch); Ctrl+C with active session calls `closeSession`. | `tests/unit/cli.test.ts`                   | `[x]`  |

---

## Phase 6 — Integration tests

Integration tests use real TLS sockets with mock router and mock host servers stood up on ephemeral ports.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                | File                                    | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|:------:|
| 6-1  | Integration test — happy path. Stand up mock router (returns one host) + mock host (accepts session, echoes one chunk + `response_end`). Drive the CLI via piped stdin: select host 1 → send a prompt → verify the echoed chunk appears on stdout → send `/exit` (or Ctrl+C) → verify clean shutdown and `session_close` observed by mock host.                                                       | `tests/integration/happy-path.test.ts`  | `[x]`  |
| 6-2  | Integration test — host busy. Mock host responds with `SessionReject reason: "busy"`. Verify the CLI displays the "host is busy" message and returns to the host-selection prompt without exiting.                                                                                                                                                                                                  | `tests/integration/rejections.test.ts`  | `[x]`  |
| 6-3  | Integration test — token expired. Mock host responds with `SessionReject reason: "invalid_token"`. Verify the CLI offers to re-fetch the host list; on confirmation, verify a new `HostListRequest` is sent to the mock router and a fresh selection is presented.                                                                                                                                  | `tests/integration/rejections.test.ts`  | `[x]`  |
| 6-4  | Integration test — session timeout mid-conversation. Mock host accepts session, accepts one prompt, then sends `SessionTimeout` instead of further chunks. Verify the CLI displays the timeout message and returns to host selection without exiting.                                                                                                                                                | `tests/integration/timeout.test.ts`     | `[x]`  |
| 6-5  | Integration test — router unreachable. No mock router is started (or its TLS port returns ECONNREFUSED). Verify the CLI exits with a clear error message and a non-zero exit code without attempting any session.                                                                                                                                                                                    | `tests/integration/startup.test.ts`     | `[x]`  |

---

## Phase 7 — CI pipeline

| #    | Task                                                                                                                                                                                                                                                                                                                                              | File                          | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|:------:|
| 7-1  | Add GitHub Actions workflow. Triggers: push to any branch, PRs targeting `main`. Steps in order: checkout, set up Node 22, `npm ci`, `npm run typecheck`, `npm run lint`, `npm run test:unit`. Run `npm run test:integration` only when the event is a PR targeting `main`. All gates must pass for the workflow to succeed.                       | `.github/workflows/ci.yml`    | `[x]`  |

---

## Phase 8 — Prompt cancellation (user side)

Adds contextual Ctrl+C support: cancels the in-flight response when generation is active; exits the program when at the input prompt. Depends on the shared protocol and host changes in host Phase 8.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | File                                      | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------|:------:|
| 8-1  | Define `PromptCancelledError` in `session-client.ts` (same pattern as `SessionTimeoutError`: `readonly code = 'PROMPT_CANCELLED' as const`). Add `cancelPrompt(): Promise<void>` to the `SessionClient` interface and implementation: sends `{ v: PROTOCOL_VERSION, type: 'prompt_cancel' }`; waits for a `prompt_cancelled` message from the host; on receipt, rejects the in-flight `sendPrompt` promise with `PromptCancelledError` and resolves the `cancelPrompt` promise. Handle `prompt_cancelled` in `handleSessionMessage` — if no prompt is in flight, treat as a no-op. Export `PromptCancelledError` alongside the other error classes at the bottom of the file. | `src/session-client.ts`                   | `[x]`  |
| 8-2  | Add `generationInFlight` boolean flag to `cli.ts`, initialised to `false`. Set it to `true` immediately before calling `sessionClient.sendPrompt(...)` and clear it in a `finally` block after the call resolves or rejects. Change the SIGINT handler: if `generationInFlight === true`, call `sessionClient.cancelPrompt()` and write `\n[stopped]\n` to `process.stdout` — **do not exit**. If `generationInFlight === false`, keep the existing close-session-and-exit behaviour. Catch `PromptCancelledError` in the conversation loop: discard the `accumulated` string, do not push an assistant turn to `messages`, and continue the loop. Update the connection banner from `Type a message, or Ctrl+C to exit.` to `Type a message, Ctrl+C to stop generation, Ctrl+C again to exit.` | `src/cli.ts`                              | `[x]`  |
| 8-3  | Unit-test the cancel path in `cli.ts`. Cases: SIGINT fires while `generationInFlight === true` → `cancelPrompt()` called, `[stopped]` printed to stdout, loop continues without exiting; SIGINT fires while `generationInFlight === false` → existing exit path runs; `PromptCancelledError` thrown by `sendPrompt` → `accumulated` is discarded, no assistant turn added to `messages`, conversation loop continues. | `tests/unit/cli.test.ts`                  | `[x]`  |
| 8-4  | Integration test — cancel mid-stream. Stand up a mock host that accepts a session, begins streaming chunks for a prompt, then receives `prompt_cancel` — at that point it stops streaming and sends `prompt_cancelled`. Verify: (a) the CLI writes `[stopped]` to stdout; (b) the session socket remains open (no `session_close` sent); (c) the CLI accepts and sends a subsequent prompt normally, and the mock host's response streams correctly to stdout. | `tests/integration/cancel.test.ts`        | `[x]`  |

---

## Phase 9 — Role-based access control (user access URL)

Adds the `key` credential to the user's router handshake flow. The router now validates a role-specific secret on every incoming connection before serving the host list; the LLMUser Router Client must parse that secret from its URL and include it in the `HostListRequest`.

**Prerequisite:** Router plan Phase 9 tasks 9-1 (S-13) and 9-2 (S-14) must be merged before this phase begins — the updated `parseFingerprintFromUrl` return type and the new `roleKey` field on `HostListRequest` are required here.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                         | File / Location                               | Status |
|------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------|:------:|
| 9-1  | Update `config.ts` Zod schema: `SHAREGRID_ROUTER_URL` must contain both `fp=sha256:[0-9a-f]+` **and** `key=[A-Za-z0-9_-]+` query params. Fail closed (exit code 1) if `key` is absent. Add unit test cases to `tests/unit/config.test.ts`: URL containing `fp` but no `key` → exits 1; URL containing neither → exits 1; URL containing both → parses correctly. Update the example URL in `docker-run.example.sh` to show the full `?fp=sha256:...&key=u-...` format. | `src/config.ts`, `tests/unit/config.test.ts`, `docker-run.example.sh` | `[x]`  |
| 9-2  | Update `createRouterClient` → `fetchHostList()`. The `parseFingerprintFromUrl` call (S-13) now returns `{ host, port, fingerprint, roleKey }`. Extract `roleKey` and pass it as the `roleKey` field in the `HostListRequest` sent to the router (S-14). No other changes to the handshake flow. | `src/router-client.ts`                        | `[x]`  |
| 9-3  | Update unit tests for `router-client.ts`. Cases: `HostListRequest` payload sent to the mock router includes the correct `roleKey` value extracted from the configured URL; URL missing `key` causes `parseFingerprintFromUrl` to throw `RoleKeyMissingError`, which propagates cleanly out of `fetchHostList()`. | `tests/unit/router-client.test.ts`            | `[x]`  |
| 9-4  | Update integration tests in `tests/integration/startup.test.ts`. Add test case: `SHAREGRID_ROUTER_URL` is configured with a valid `fp` and a syntactically valid `key`, but the mock router rejects the connection because the `key` does not match its user secret — verify the CLI exits with a clear error message and a non-zero exit code without displaying a host list or attempting any session. | `tests/integration/startup.test.ts`           | `[x]`  |

---

## Status ledger

Update this table whenever a task changes state. The phase rows are the source of truth; do not let the per-task tables and this ledger diverge.

| Phase | Title                                  | Total | Done | In progress | Blocked | Remaining |
|-------|----------------------------------------|:-----:|:----:|:-----------:|:-------:|:---------:|
| 0     | Prerequisite: `sharegrid-shared` (satisfied via host plan S-1–S-8 and router plan S-9–S-12) | 0     | 0    | 0           | 0       | 0         |
| 1     | Repo scaffolding (`sharegrid-user`)    | 6     | 6    | 0           | 0       | 0         |
| 2     | Infrastructure modules                 | 3     | 3    | 0           | 0       | 0         |
| 3A    | Router Client                          | 4     | 4    | 0           | 0       | 0         |
| 3B    | Session Client                         | 7     | 7    | 0           | 0       | 0         |
| 3C    | CLI                                    | 7     | 7    | 0           | 0       | 0         |
| 3D    | Entry point                            | 2     | 2    | 0           | 0       | 0         |
| 4     | Dockerfile                             | 3     | 3    | 0           | 0       | 0         |
| 5     | Unit tests                             | 4     | 4    | 0           | 0       | 0         |
| 6     | Integration tests                      | 5     | 5    | 0           | 0       | 0         |
| 7     | CI pipeline                            | 1     | 1    | 0           | 0       | 0         |
| 8     | Prompt cancellation (user side)        | 4     | 4    | 0           | 0       | 0         |
| 9     | Role-based access control (user access URL) | 4 | 4    | 0           | 0       | 0         |
| —     | **Total**                              | **50**| **50**| **0**      | **0**   | **0**     |

### Notes / blockers

- **Phase 1 complete.** `sharegrid-user` scaffolded at `../sharegrid-user` (commit `f57dc01`) and pushed to <https://github.com/MartijnLammaing/sharegrid-user>. `npm install` clean (195 packages, engine warnings only). `tsc --noEmit` passes with zero errors.
- **Prerequisite satisfied.** `sharegrid-shared` v0.1.0 is published at <https://github.com/MartijnLammaing/sharegrid-shared> (commit `052ed3d`). All twelve shared items (S-1 through S-12) referenced by this plan are complete; the LLMUser module is unblocked for Phase 1.

---

## Conventions reminder for implementers

- Source files: `kebab-case.ts`. Classes: `PascalCase`. Functions/variables: `camelCase`. (See `implementation_guidelines.md` §3.)
- Named exports only. No default exports.
- `async`/`await` only. No raw `.then()` chains.
- No `TODO` comments merged to `main` — open an issue instead.
- Conventional Commits with scope `user`: e.g. `feat(user): add session client prompt/response streaming`.
- One PR per task or per tightly related task cluster. CI must be green before merge.
- **CLI output convention** (specific to this repo): user-facing output goes to `process.stdout` via `process.stdout.write`; diagnostic logging goes to `process.stderr` via the `pino` logger. Never mix these — the user's terminal experience must not be polluted by structured logs.
