# LLMRouter — Component Architecture

> **Scope:** Phase 1 (MVP). See [`architecture_overview.md`](./architecture_overview.md) for system-wide context, security model, and the phase roadmap.

---

## 1. Responsibilities (Phase 1)

The LLMRouter has three distinct concerns that must be kept architecturally separate:

1. **Registry authority** — maintain live, in-memory registries of active LLMHost and LLMUser entries; evict stale entries automatically.
2. **Key issuance** — be the sole trust anchor for the network; sign host key tokens that LLMUsers present to open sessions.
3. **Broker, not proxy** — facilitate the initial handshake, then step aside. The router never observes or relays inference traffic.

---

## 2. Internal Component Structure

The LLMRouter is a single, stateless process (stateless about conversation content; stateful about registrations). It exposes one TLS endpoint that both LLMHosts and LLMUsers connect to.

```mermaid
graph TB
    subgraph LLMRouter Process
        TLS[TLS Listener]
        KA[Key Authority]
        HR[Host Registry]
        UR[User Registry]
    end

    H([LLMHost]) -- "TLS: register / heartbeat" --> TLS
    U([LLMUser]) -- "TLS: handshake / host list" --> TLS

    TLS -- "sign host key" --> KA
    KA -- "signed host key token" --> TLS
    TLS -- "add / update / evict" --> HR
    TLS -- "add / evict" --> UR
    HR -- "host list" --> TLS
```

### 2.1 TLS Listener

The single inbound endpoint for the network. Responsibilities:

- Accept TLS connections from both LLMHosts (registration + heartbeat) and LLMUsers (handshake + host list request).
- Demux the connection type from the initial message and route to the appropriate handler.
- Enforce that all connections present valid TLS; reject any plaintext or self-signed connections that do not match the expected fingerprint.
- Return errors fast — reject, close, and log; no partial state is written on failure.

### 2.2 Key Authority

Owns the router's Ed25519 signing key — the trust anchor for the entire network. Responsibilities:

- Hold the Ed25519 private key in memory only. It is never written to disk.
- On host registration, issue a **host key token**: a signed payload containing the host identifier, the host's TLS cert fingerprint, and an expiry timestamp.
- Expose the corresponding **Ed25519 public key** to outbound responses so that LLMHosts can verify tokens presented by LLMUsers.
- Have no external interface; only the TLS Listener may invoke it.

> On router restart, the private key is gone. All previously issued host key tokens are immediately invalid — their signature can no longer be verified against the new key. All hosts must re-register and all users must reconnect. This is intentional: no stale credentials survive a router restart.

### 2.3 Host Registry

An in-memory map of currently active LLMHosts. Each entry holds:

| Field | Description |
|-------|-------------|
| `host_id` | Opaque identifier assigned at registration |
| `model_name` | Human-readable model name, as reported by the host |
| `context_size` | Context window size in tokens |
| `endpoint` | Host address + port for direct LLMUser connections |
| `tls_fingerprint` | TLS cert fingerprint for LLMUser cert pinning |
| `host_key_token` | The signed token issued by the Key Authority |
| `last_seen` | Timestamp of the most recent heartbeat |

Responsibilities:

- Add an entry on successful host registration.
- Update `last_seen` on each heartbeat.
- Run a background eviction loop: remove any host whose `last_seen` exceeds the configured heartbeat timeout. An evicted host is immediately absent from the host list returned to LLMUsers.
- Return the full host list (all non-evicted entries) on request.

### 2.4 User Registry

An in-memory map of currently active LLMUser sessions. Each entry holds:

| Field | Description |
|-------|-------------|
| `session_token` | Opaque anonymous token issued at handshake |
| `last_seen` | Timestamp of the most recent interaction with the router |

Responsibilities:

- Issue a **session token** at handshake and record the entry.
- Update `last_seen` on each interaction.
- Evict inactive sessions after the configured inactivity timeout.
- Support **forced eviction** by an operator: a session token can be invalidated immediately, which causes the next router interaction from that user to be rejected. This is the mechanism for enforcing code of conduct decisions (see §4).

---

## 3. Connection Flows

### 3.1 LLMHost Registration

For the full registration flow in system context, see [`architecture_overview.md`](./architecture_overview.md) §4.1. The router-side view:

```mermaid
sequenceDiagram
    participant H as LLMHost
    participant TLS as TLS Listener
    participant KA as Key Authority
    participant HR as Host Registry

    H->>TLS: TLS connect + registration payload<br/>(model metadata, port, TLS cert fingerprint)
    TLS->>TLS: Validate payload (required fields present, port in valid range)
    TLS->>KA: Request host key token<br/>(host_id, tls_fingerprint, expiry)
    KA->>KA: Sign payload with Ed25519 private key
    KA-->>TLS: Signed host key token
    TLS->>HR: Add host entry<br/>(metadata + token + last_seen = now)
    TLS-->>H: Host key token + router Ed25519 public key

    loop Heartbeat
        H->>TLS: Heartbeat ping
        TLS->>HR: Update last_seen
    end

    Note over HR: Background loop evicts hosts<br/>with expired last_seen
```

### 3.2 LLMUser Handshake

```mermaid
sequenceDiagram
    participant U as LLMUser CLI
    participant TLS as TLS Listener
    participant UR as User Registry
    participant HR as Host Registry

    U->>TLS: TLS connect + handshake request
    TLS->>UR: Create session entry<br/>Issue session token
    UR-->>TLS: Session token
    TLS->>HR: Fetch current host list
    HR-->>TLS: Active host entries
    TLS-->>U: Session token + host list<br/>(model metadata, endpoint, tls_fingerprint, host_key_token)

    Note over U: User selects a host and opens<br/>a direct TLS session — router is no longer involved

    U->>TLS: Session ended (optional notification)
    TLS->>UR: Evict session entry
```

---

## 4. Security Design

### 4.1 Key Authority — Ed25519 Key Storage

The router's Ed25519 private key is held in process memory only and is never written to disk or passed to any other process. Consequences are the same as for LLMHost key storage: a router restart invalidates all previously issued host key tokens and all active session tokens. Hosts must re-register; users must reconnect.

The router's **public key** is distributed to LLMHosts as part of the registration response. LLMHosts use it to verify the host key token that a LLMUser presents when opening a session. The public key may also be pre-configured out-of-band as a trust anchor.

### 4.2 Host Key Token Format

The host key token is an Ed25519-signed payload. The signed content includes:

| Field | Purpose |
|-------|---------|
| `host_id` | Ties the token to a specific host; LLMHost rejects tokens issued for a different host |
| `tls_fingerprint` | The host's TLS cert fingerprint; LLMUser pins to this before presenting the token |
| `expires_at` | UTC timestamp; LLMHost rejects expired tokens |

The token is opaque to both the LLMHost and LLMUser. Its only valid use is presentation — the LLMHost verifies the signature and fields; it does not parse or act on the payload content beyond that. See also [`architecture_overview.md`](./architecture_overview.md) §9 (Router-issued host keys).

### 4.3 User Authentication — Anonymous Session Tokens

The overview specifies that LLMUsers are authenticated, but does not prescribe a mechanism. **Proposed approach for Phase 1:** anonymous session tokens.

On handshake, the router issues a randomly generated opaque token to the LLMUser — no credentials, no identity, no account. The token:

- Is a cryptographically random 256-bit value.
- Is stored in the User Registry alongside a `last_seen` timestamp.
- Has no signature and carries no claims. It is an opaque handle, not a verifiable credential.
- Is used solely to identify a session for the purpose of forced eviction.

**Why this is sufficient for Phase 1:** the only action the router needs to take against a user is to terminate their router-side session (evict the session token, reject subsequent requests). The user's inference session with the LLMHost is direct and independent; the router cannot terminate it. Forced eviction prevents the user from obtaining a new host list or re-entering the network without reconnecting.

**Code of conduct enforcement flow:**

```mermaid
sequenceDiagram
    participant OP as Router Operator
    participant UR as User Registry
    participant U as LLMUser CLI

    OP->>UR: Evict session_token (operator action)
    UR->>UR: Remove session entry

    U->>TLS: Any subsequent request with session_token
    TLS->>UR: Look up session_token
    UR-->>TLS: Not found
    TLS-->>U: Rejected (401)
```

> This does not terminate an in-flight inference session on the LLMHost — that is a host-side action. The router operator would need to coordinate with the relevant host operator to interrupt an active session. This limitation is acceptable for Phase 1.

### 4.4 Trust Boundary

The router is a trusted coordinator. It does not observe inference traffic, which limits its exposure to conversation data. Its main attack surface is the TLS listener and the Key Authority's private key.

See [`architecture_overview.md`](./architecture_overview.md) §5 for the full system trust boundary, including the treatment of malicious host operators.

---

## 5. Failure Handling

| Failure | Response |
|---------|----------|
| LLMHost stops heartbeating | Host Registry evicts the entry after the timeout. Host disappears from the list returned to new LLMUser handshakes. No active user sessions are affected — they are direct. |
| LLMHost reconnects after eviction | Treated as a new registration. Key Authority issues a new host key token. Previous token is invalid (different `host_id` or expired). |
| LLMUser goes inactive | User Registry evicts the session token after the inactivity timeout. The user must reconnect and perform a new handshake to get a fresh host list. |
| Router restarts | All registry state is lost. All previously issued host key tokens are invalid (new Ed25519 key generated). All hosts must re-register. All users must reconnect. |
| Key Authority unavailable (e.g. memory pressure) | Host registration is rejected. No partial state is written. The host retries with backoff per its Router Client logic. |

---

## 6. Configuration

The router is configured via environment variables on startup.

| Variable | Required | Description | Example |
|----------|:--------:|-------------|---------|
| `SHAREGRID_LISTEN_ADDR` | Yes | Address and port the TLS Listener binds to | `0.0.0.0:8443` |
| `SHAREGRID_TLS_CERT` | Yes | Path to the router's TLS certificate | `/etc/sharegrid/router.crt` |
| `SHAREGRID_TLS_KEY` | Yes | Path to the router's TLS private key | `/etc/sharegrid/router.key` |
| `SHAREGRID_HEARTBEAT_TIMEOUT` | No | Seconds before a host with no heartbeat is evicted. Default: `90` | `90` |
| `SHAREGRID_SESSION_TIMEOUT` | No | Seconds before an inactive user session is evicted. Default: `300` | `300` |

If any required variable is absent, the router must exit immediately with a clear error rather than starting in a partially configured state.

---

## 7. Phase Roadmap — LLMRouter Impact

| Phase | Change | What it means for LLMRouter |
|-------|--------|-----------------------------|
| **1** | MVP | Architecture described in this document. |
| **2** | Structured tool-call responses on the host side | No router changes required. The User ↔ Host channel is direct. |
| **3** | Controlled internet access for LLMHost | No router changes required. Internet policy is enforced at the container level. |
| **4** | Multiple simultaneous hosts and users; session reservation | Host Registry must track busy/free status per host. TLS Listener must handle host status update messages. User handshake response must surface host availability. |
| **Future** | Multiple routers, load balancing, resource accounting | Router becomes a distributed or federated service. Host and User registries need a shared backing store. Key Authority must support key rotation without invalidating all live tokens. |

---

## 8. Open Design Decisions

| # | Question | Status | Notes |
|---|----------|--------|-------|
| 1 | **User authentication mechanism** | Proposed — see §4.3 | Anonymous session tokens. No identity required. Token is opaque handle for eviction only. |
| 2 | **Host key token TTL** | Open | Must be long enough to survive a slow handshake; short enough to limit the window for a stolen token. A starting point: 5 minutes from issuance. |
| 3 | **Heartbeat eviction timeout** | Open | Must be longer than the configured heartbeat interval on the LLMHost side (default 30 s). Starting point: `3 × heartbeat_interval`. |
| 4 | **Ed25519 key provisioning** | Open | Phase 1: generated fresh on each router startup (simplest; consequences documented in §4.1). Alternative: load from a file to survive restarts. Tradeoff: persistent key increases impact of key compromise. |
| 5 | **Operator eviction interface** | Open | §4.3 assumes an operator can invoke forced eviction. The mechanism (admin CLI, local HTTP endpoint, signal handler) is unspecified. |
