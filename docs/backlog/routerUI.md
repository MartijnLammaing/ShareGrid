# Router Admin UI

## Goal
Add a web-based admin UI for the sharegrid router instance that is reachable via a localhost URL.

## Required functionality
- Bump (kick) a connected user out of the registry.
- Bump (kick) a connected host out of the registry.
- Follow macOS-native host logs in the UI.
- Follow Docker-hosted logs in the UI.
- Show the connection string for both user and host roles in the UI.

## Open design questions

### 1. Admin endpoint / access model
- Should the UI be reachable only from the same machine (localhost), or from anywhere?
- Proposed default: a separate local-only HTTP admin server bound to `127.0.0.1:<port>` (e.g. `SHAREGRID_ADMIN_PORT=8080`).
- In Docker this would be published as `127.0.0.1:8080:8080`.

### 2. Authentication
- Should the admin UI use its own admin secret, or reuse the host/user role secrets?
- Proposed: generate a new admin secret alongside the host/user secrets and print an admin URL in the startup banner.

### 3. User registry semantics
- To “bump out a user”, the router must first track user sessions.
- Current code only handles one-shot host-list requests and closes the connection.
- Proposed: create a user session entry on every successful `host_list_request` with a session ID and token, plus a background eviction loop.
- Open: should “bump user” revoke the token entirely, or just remove the session entry?

### 4. User tracking granularity
- Should we track every user that fetches the host list, or only users that have an open session to a host?
- Today the host only reports `activeSessions` count, not per-user identities.
- Open: do we want hosts to report per-session user identifiers?

### 5. Log streaming approach
- Docker logs: the router does not have access to the Docker daemon by default.
- macOS native logs: the router does not have access to the host filesystem.
- Proposed: extend the router-host protocol with a `log_line` message so hosts forward their own logs (and optionally `llama-server` logs) to the router over the existing TLS connection. The router stores a bounded per-host log buffer and streams it via SSE in the UI.
- Open: is host self-forwarding acceptable, or do you want the router to read Docker / macOS logs directly?

### 6. “Bump out” semantics
- Host: remove registry entry, close TLS socket, mark host ID as revoked so reconnection is rejected.
- User: remove user session entry and revoke that token.
- Open: should the router also ask the host to close an active user session?

### 7. Frontend technology
- Options:
  - Vanilla HTML/JS (minimal dependencies)
  - HTMX
  - React/Vue
- Proposed: vanilla HTML/JS with SSE for live logs and fetch for bump actions, served from a small embedded static file directory.

## Proposed implementation outline

1. **Architecture document update** — add an Admin UI section to `docs/architecture_llmrouter.md`.
2. **Shared protocol extension** in `sharegrid-shared/src/protocol.ts`:
   - User session tracking
   - `log_line` message type (host → router)
   - Admin messages if needed
3. **Router changes**:
   - Add `src/user-registry.ts`
   - Add revocation list / token denylist
   - Extend `src/tls-listener.ts` to populate user registry and enforce revocations
   - Add `src/admin-server.ts` (HTTP + SSE)
   - Add log buffer / aggregator
4. **Host changes**:
   - Add log-forwarding component
   - Forward pino logs and optionally `llama-server` stdout/stderr as `log_line` messages
5. **Docker / launch scripts**:
   - Expose admin port in `sharegrid-router/docker-run.sh`
   - Expose admin port in `start-dev.sh`
6. **Tests**:
   - Unit tests for user registry and revocation
   - Integration tests for admin API and log streaming
   - Manual browser verification

## Current state

- `sharegrid-router` is a Node.js TypeScript service with one TLS listener for hosts and users.
- It has an in-memory host registry (`host-registry.ts`) with `add`, `remove`, `updateHeartbeat`, `updateStatus`, and `list`.
- It does **not** currently track user sessions. A user connection just requests the host list and is immediately closed.
- There is no HTTP/localhost endpoint at all today.
- Host logs are emitted to container stdout/stderr by the host process and `llama-server`; the macOS native host writes to a log file when started via `start-dev.sh --macos-host`. The router has no access to either.

## Decisions needed
Please fill in your answers below:

- [ ] Admin bind address/port:
- [ ] Auth model (new admin secret / reuse host secret / reuse user secret / no auth):
- [ ] User tracking scope (host-list request only / host-list + active host sessions):
- [ ] Log source (host self-forwarding / router reads Docker / router reads macOS files):
- [ ] Bump-user behaviour (revoke token / also notify host to close session):
- [ ] Frontend style (vanilla JS / HTMX / React / Vue / other):
