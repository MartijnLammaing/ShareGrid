# ShareGrid — Technical Implementation Guidelines

> **Scope:** All phases. Applies to all four repositories: `sharegrid-shared`, `sharegrid-router`, `sharegrid-host`, `sharegrid-user`.

---

## 1. Language & Runtime

**TypeScript** with **Node.js v22 LTS**.

- All repos use `"strict": true` in `tsconfig.json`. No `any` — use `unknown` with type narrowing.
- `tsc` is used for type checking only, not as the build tool (see §8 Build).
- The Node.js built-in `crypto`, `net`, and `tls` modules cover all cryptographic and networking requirements. No third-party crypto or TLS libraries.

> **LLMHost Docker image:** uses `gcr.io/distroless/nodejs22-debian12` — a minimal Node.js base with no shell, no package manager, and no debugging tools, consistent with the hardening requirements in `architecture_llmhost.md` §5.3.

---

## 2. Repository Structure

Four repositories under the same GitHub organisation:

| Repo | Description |
|------|-------------|
| `sharegrid-shared` | Shared TypeScript package published as `@sharegrid/shared` |
| `sharegrid-router` | LLMRouter process + Dockerfile |
| `sharegrid-host` | LLMHost process + Dockerfile |
| `sharegrid-user` | LLMUser CLI + Dockerfile |

`sharegrid-shared` is a **foundational shared package**. All three component repos depend on it for protocol types, crypto helpers, TLS utilities, and typed error classes. Its public interfaces must be defined before component implementation begins. Component repos reference it by file path (see §2.3).

### 2.1 Per-component repo layout

```
src/
  index.ts              # process entry point (env validation, startup, signal handling)
  config.ts             # env var parsing and validation (see §9)
  <component>.ts        # one file per named architectural component
tests/
  unit/
  integration/
Dockerfile
package.json
tsconfig.json
tsconfig.build.json     # same as tsconfig.json but excludes tests/
.github/
  workflows/
    ci.yml
```

Components map directly to the architecture documents. For example, `sharegrid-router` contains:

```
src/
  index.ts
  config.ts
  tls-listener.ts
  key-authority.ts
  host-registry.ts
```

### 2.2 `sharegrid-shared` layout

```
src/
  protocol.ts     # wire message interfaces
  crypto.ts       # Ed25519 sign/verify helpers
  tls.ts          # TLS fingerprint parsing and pinning utilities
  errors.ts       # shared typed error classes
index.ts          # re-exports everything
package.json
tsconfig.json
```

`@sharegrid/shared` has **zero runtime dependencies** — Node.js built-ins only.

### 2.3 Local development reference

Component repos reference the shared package by file path:

```json
{
  "dependencies": {
    "@sharegrid/shared": "file:../sharegrid-shared"
  }
}
```

---

## 3. File & Folder Naming

| What | Convention | Example |
|------|------------|---------|
| Source files | `kebab-case.ts` | `host-registry.ts` |
| Folders | `kebab-case/` | `tests/integration/` |
| Test files | `<subject>.test.ts` | `host-registry.test.ts` |
| Classes | `PascalCase` | `HostRegistry` |
| Interfaces | `PascalCase` (no `I` prefix) | `HostEntry` |
| Functions | `camelCase` | `createHostRegistry()` |
| Variables | `camelCase` | `currentToken` |
| Environment variable names | `SCREAMING_SNAKE_CASE` | `SHAREGRID_LISTEN_ADDR` |

---

## 4. Code Style

**Formatter:** Prettier. Format on save; enforced in CI. No style debates in code review.

**Linter:** ESLint with `@typescript-eslint`. Zero warnings permitted in CI.

The following conventions are non-negotiable:

### Named exports only

```ts
// ✅
export function createHostRegistry(config: RegistryConfig): HostRegistry { ... }

// ❌
export default function createHostRegistry(config: RegistryConfig) { ... }
```

### Interfaces for data shapes; `type` for unions and aliases

```ts
// ✅
interface HostEntry {
  hostId: string;
  modelName: string;
  contextSize: number;
  endpoint: string;
  tlsFingerprint: string;
  hostKeyToken: string;
  lastSeen: Date;
}

type ConnectionState = "connecting" | "registered" | "disconnected";

// ❌ — type alias for a plain object shape
type HostEntry = {
  hostId: string;
  ...
};
```

### Async/await only — no raw Promise chains

```ts
// ✅
async function register(payload: RegistrationPayload): Promise<HostKey> {
  const token = await keyAuthority.sign(payload);
  hostRegistry.add(payload.hostId, token);
  return token;
}

// ❌
function register(payload: RegistrationPayload): Promise<HostKey> {
  return keyAuthority.sign(payload).then(token => {
    hostRegistry.add(payload.hostId, token);
    return token;
  });
}
```

### No `TODO` comments merged to `main`

Open a GitHub issue instead. A `TODO` in a PR is a signal the work is incomplete.

---

## 5. Error Handling

Two categories, handled differently:

**Unrecoverable / configuration errors** — log and exit. Never swallow these.

```ts
// In index.ts, before anything else starts:
const result = Config.safeParse(process.env);
if (!result.success) {
  logger.error({ errors: result.error.flatten() }, "invalid configuration");
  process.exit(1);
}
```

**Expected failure paths** — typed error classes from `@sharegrid/shared/errors`. Callers check the type; they do not parse error messages.

```ts
// errors.ts (in @sharegrid/shared)
export class HostBusyError extends Error {
  readonly code = "HOST_BUSY" as const;
}

export class InvalidTokenError extends Error {
  readonly code = "INVALID_TOKEN" as const;
}

// session-manager.ts
import { HostBusyError, InvalidTokenError } from "@sharegrid/shared/errors";

if (sessionSlot.isOccupied()) {
  throw new HostBusyError("session slot occupied");
}

// caller
try {
  await sessionManager.open(connection);
} catch (err) {
  if (err instanceof HostBusyError) {
    connection.reject(503, "host is busy");
    return;
  }
  throw err; // re-throw anything unexpected
}
```

Never catch `unknown` errors and silently swallow them. If you catch, either handle specifically or re-throw.

---

## 6. Protocol & Message Framing

All communication between components (Router ↔ Host, Router ↔ User) uses **newline-delimited JSON** over TLS: each message is a single-line JSON object terminated by `\n`.

The receiver buffers incoming bytes and parses a message each time it encounters a `\n`. JSON values must not contain literal newlines (use `\n` escape sequences in string values if needed).

### Scope

The newline-delimited JSON framing described in this section applies to **all** component connections: Router ↔ Host, Router ↔ User, and **Host ↔ User**. See §6.1 for the Host ↔ User session message types.

### Version field

Every message carries a `v` field set to `1`. This allows future phases to introduce new message formats while remaining backward-compatible: a receiver that sees an unknown `v` can reject the connection with a clear error rather than misinterpreting the payload.

```
{"v":1,"type":"register","modelName":"llama-3-8b-instruct-q4",...}\n
```

The current protocol version is defined as a single constant in `@sharegrid/shared/protocol.ts`:

```ts
export const PROTOCOL_VERSION = 1 as const;
```

Senders always set `v: PROTOCOL_VERSION`. Receivers reject any message where `v` is absent or does not match the supported version.

### Message interfaces

Message types are defined as interfaces in `@sharegrid/shared/protocol.ts`:

```ts
// protocol.ts
export interface RegistrationPayload {
  v: typeof PROTOCOL_VERSION;
  type: "register";
  modelName: string;
  contextSize: number;
  port: number;
  tlsFingerprint: string;
}

export interface RegistrationAck {
  v: typeof PROTOCOL_VERSION;
  type: "register_ack";
  hostId: string;
  hostKeyToken: string;
  routerPublicKey: string;
}

export interface HeartbeatPayload {
  v: typeof PROTOCOL_VERSION;
  type: "heartbeat";
  hostId: string;
}

export interface HeartbeatAck {
  v: typeof PROTOCOL_VERSION;
  type: "heartbeat_ack";
  hostKeyToken: string;
}
```

All message interfaces include a `type` discriminant field. Use a discriminated union when handling incoming messages:

```ts
type IncomingMessage = RegistrationPayload | HeartbeatPayload;

function handleMessage(msg: IncomingMessage): void {
  switch (msg.type) {
    case "register":
      handleRegistration(msg);
      break;
    case "heartbeat":
      handleHeartbeat(msg);
      break;
    default:
      msg satisfies never; // compile error if a case is missing
  }
}
```

### 6.1 LLMUser ↔ LLMHost session protocol

The Session Manager is a raw TLS server. The LLMUser ↔ LLMHost session uses the same newline-delimited JSON framing as all other connections. Message types defined in `@sharegrid/shared/protocol.ts`:

```ts
// Session open — first message from LLMUser after TLS connect
export interface SessionOpenPayload {
  v: typeof PROTOCOL_VERSION;
  type: "session_open";
  hostKeyToken: string;
}

// Session accepted — sent by LLMHost
export interface SessionAck {
  v: typeof PROTOCOL_VERSION;
  type: "session_ack";
}

// Session rejected — sent by LLMHost
export interface SessionReject {
  v: typeof PROTOCOL_VERSION;
  type: "session_reject";
  reason: "busy" | "invalid_token" | "not_registered";
}

// Prompt — sent by LLMUser
export interface PromptPayload {
  v: typeof PROTOCOL_VERSION;
  type: "prompt";
  messages: Array<{ role: string; content: string }>;
}

// Response chunk — sent by LLMHost, one or more per prompt
export interface ResponseChunk {
  v: typeof PROTOCOL_VERSION;
  type: "response_chunk";
  content: string;
}

// Response complete — sent by LLMHost after the final chunk
export interface ResponseEnd {
  v: typeof PROTOCOL_VERSION;
  type: "response_end";
}

// Graceful close — either party
export interface SessionClose {
  v: typeof PROTOCOL_VERSION;
  type: "session_close";
}

// Idle timeout — sent by LLMHost before closing the connection
export interface SessionTimeout {
  v: typeof PROTOCOL_VERSION;
  type: "session_timeout";
}
```

### 6.2 LLMUser ↔ LLMRouter host-list protocol

The LLMUser fetches the active host list from the LLMRouter using the same newline-delimited JSON framing as every other connection. The exchange is a single request/response: the user opens a TLS connection (pinned to the router's fingerprint), sends one `HostListRequest`, receives one `HostListResponse`, and the router closes the connection. The router is not involved in any subsequent traffic — see `architecture_llmrouter.md` §3.2.

Message types defined in `@sharegrid/shared/protocol.ts`:

```ts
// Host list request — first and only message from LLMUser after TLS connect
export interface HostListRequest {
  v: typeof PROTOCOL_VERSION;
  type: "host_list_request";
}

// One entry in the host list returned to LLMUsers
export interface HostListEntry {
  hostId: string;
  modelName: string;
  contextSize: number;
  endpoint: string;        // host:port the user connects to directly
  tlsFingerprint: string;  // sha256:<hex>; user pins TLS to this before opening a session
  hostKeyToken: string;    // opaque, presented to the host as session credential
}

// Host list response — sent by LLMRouter, then the router closes the connection
export interface HostListResponse {
  v: typeof PROTOCOL_VERSION;
  type: "host_list_response";
  hosts: HostListEntry[];
}
```

### 6.3 Host key token wire format

The `hostKeyToken` field that appears in `RegistrationAck`, `HeartbeatAck`, `HostListEntry`, and `SessionOpenPayload` is an opaque, dot-separated two-part string:

```
base64url(JSON.stringify(payload)) + "." + base64url(ed25519_signature)
```

The signed payload has the shape:

```ts
export interface HostKeyTokenPayload {
  hostId: string;
  tlsFingerprint: string;  // sha256:<hex>
  expiresAt: number;       // Unix epoch milliseconds
}
```

The Ed25519 signature is computed over the **base64url-encoded payload string** (the first part), not over the raw JSON. See `architecture_llmrouter.md` §4.2 for the authoritative specification.

The token is opaque to the LLMUser — it is presented verbatim to the LLMHost without inspection. Encoding and decoding helpers live in `@sharegrid/shared` (see the `crypto` / `token` modules).

---

## 7. Testing

**Framework:** Vitest.

### Structure

- `tests/unit/` — pure logic, no I/O. Tests a single function or class in isolation. External dependencies are mocked at the boundary.
- `tests/integration/` — real TLS sockets, real timers. Spins up actual component instances. No mocks.

### Conventions

- One test file per source file: `src/host-registry.ts` → `tests/unit/host-registry.test.ts`.
- Use `it.each` for validation and crypto paths where multiple inputs exercise the same logic.
- Mock only at I/O boundaries (network, clock, filesystem). Do not mock internal functions.
- Every public function has at least one unit test. Every failure mode listed in the architecture documents has an integration test.

### Example

```ts
// tests/unit/host-registry.test.ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { HostRegistry } from "../../src/host-registry";

describe("HostRegistry", () => {
  it("evicts hosts whose last_seen exceeds the timeout", () => {
    const registry = new HostRegistry({ heartbeatTimeoutMs: 90_000 });
    const now = Date.now();

    registry.add(fakeEntry({ lastSeen: now - 100_000 })); // stale
    registry.add(fakeEntry({ lastSeen: now - 10_000 }));  // fresh

    registry.evictStale(now);

    expect(registry.list()).toHaveLength(1);
  });

  it.each([
    { lastSeen: Date.now() - 89_000, expected: 1 },
    { lastSeen: Date.now() - 91_000, expected: 0 },
  ])("boundary: lastSeen $lastSeen ms ago → $expected host(s)", ({ lastSeen, expected }) => {
    const registry = new HostRegistry({ heartbeatTimeoutMs: 90_000 });
    registry.add(fakeEntry({ lastSeen }));
    registry.evictStale(Date.now());
    expect(registry.list()).toHaveLength(expected);
  });
});
```

### CI gates (in order)

1. `tsc --noEmit` — type check
2. `eslint src/` — lint
3. `vitest run tests/unit` — unit tests
4. `vitest run tests/integration` — integration tests (PRs to `main` only)

All gates must pass before a PR can be merged.

---

## 8. Build

Each component repo uses `esbuild` to bundle `src/` into a single `dist/bundle.cjs` before the Docker image is built. This eliminates `node_modules` from the image layer. For local development, `tsx` runs TypeScript directly without a build step.

> **`sharegrid-host` Dockerfile** uses a three-stage build: (1) a llama.cpp builder stage (Debian slim + cmake, CPU-only, pinned git tag), (2) a Node.js builder stage (esbuild bundle), and (3) the distroless runtime stage. Only `dist/bundle.cjs` and the `llama-server` binary are copied into the final image. See `architecture_llmhost.md` §5.3 for the full specification.

```json
// package.json scripts
{
  "scripts": {
    "build": "esbuild src/index.ts --bundle --platform=node --target=node22 --outfile=dist/bundle.cjs",
    "typecheck": "tsc --noEmit",
    "lint": "eslint src/",
    "test:unit": "vitest run tests/unit",
    "test:integration": "vitest run tests/integration",
    "dev": "tsx src/index.ts"
  }
}
```

The Dockerfile copies only `dist/bundle.cjs` — no `package.json`, no `node_modules`:

```dockerfile
FROM gcr.io/distroless/nodejs22-debian12
COPY dist/bundle.cjs /app/bundle.cjs
CMD ["/app/bundle.cjs"]
```

---

## 9. Configuration

All environment variables are parsed and validated at process startup using `zod`. The process exits immediately with a descriptive error if any required variable is absent or malformed. No component ever starts in a partially configured state.

```ts
// config.ts
import { z } from "zod";

const Config = z.object({
  SHAREGRID_LISTEN_ADDR: z.string().regex(/^.+:\d{1,5}$/, "must be host:port"),
  SHAREGRID_HEARTBEAT_TIMEOUT: z.coerce.number().int().positive().default(90),
});

export type Config = z.infer<typeof Config>;

export function loadConfig(): Config {
  const result = Config.safeParse(process.env);
  if (!result.success) {
    console.error("Configuration error:\n" + result.error.flatten().fieldErrors);
    process.exit(1);
  }
  return result.data;
}
```

`zod` is the only configuration dependency permitted. Do not reach into `process.env` anywhere other than `config.ts`.

---

## 10. Logging

**Library:** `pino` with JSON output. In development, pipe through `pino-pretty`.

Every log entry must include a `component` field identifying the source. No `console.log` in production code paths — only `console.error` in `config.ts` before the logger is initialised (see §9).

```ts
// In each component file:
import { logger } from "./logger"; // re-exports a pino child with { component }

logger.info({ hostId, endpoint }, "host registered");
logger.warn({ hostId }, "host heartbeat timeout — evicting");
logger.error({ err }, "slot erase failed — exiting");
```

Log levels:
- `error` — the process is about to exit or a session was aborted
- `warn` — degraded state, recoverable (e.g. eviction, reconnect attempt)
- `info` — normal lifecycle events (startup, registration, session open/close)
- `debug` — per-message tracing; disabled in production

---

## 11. Version Control Strategy

### Branches

- `main` is always deployable and build-passing.
- Feature work: `feat/<short-description>` — e.g. `feat/host-registry-eviction`
- Bug fixes: `fix/<short-description>` — e.g. `fix/session-teardown-race`
- Branches are short-lived. Delete after merge.

### Pull requests

- All changes go through a PR, even when working solo. PRs are the record of intent.
- **Squash merge** to `main` — one commit per feature.
- `main` is branch-protected: CI must pass before merge.

---

## 12. Commit Format

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <imperative summary>

[optional body — explain why, not what]
[optional footer — BREAKING CHANGE or Closes #<issue>]
```

**Types:** `feat`, `fix`, `chore`, `test`, `docs`, `refactor`, `ci`

**Scopes:** `router`, `host`, `user`, `shared`

**Examples:**

```
feat(router): add host registry with heartbeat eviction
fix(host): exit container if slot erase fails after session teardown
chore(shared): add Ed25519 sign/verify helpers
test(router): cover token refresh overlap window
docs: add implementation guidelines
ci(host): add GitHub Actions workflow with type check and tests
```

Rules:
- Summary is lowercase, imperative mood, no trailing period
- Summary line max 72 characters
- Body only when the "why" is not obvious from the summary

---

## 13. Dependency Policy

- **`@sharegrid/shared`**: zero runtime dependencies — Node.js built-ins only.
- **Component repos**: minimal. Permitted runtime dependencies:
  - `zod` — configuration validation
  - `pino` — structured logging
  - `selfsigned` (`sharegrid-host` and `sharegrid-router`) — self-signed X.509 certificate generation. `sharegrid-host` generates an ephemeral cert at every process startup (memory only). `sharegrid-router` generates a cert on first startup and persists it to a fixed internal path so the fingerprint stays stable across `docker stop`/`docker start` cycles (see `architecture_llmrouter.md` §6.1). Node.js has no built-in API for X.509 generation; `selfsigned` wraps Node.js's own `crypto` primitives and introduces no third-party cryptographic implementation.
- No dependency is added without a clear justification. Prefer the Node.js stdlib. Any new dependency requires a note in the PR description explaining why the stdlib is insufficient.
- `esbuild`, `tsx`, `vitest`, `eslint`, `prettier`, and `typescript` are dev dependencies only — they never appear in the bundled output.
