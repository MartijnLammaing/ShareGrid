# ShareGrid — System Architecture Overview

> **Scope:** Phase 1 (MVP). Future-phase concerns are noted where they influence design decisions, but are not implemented in Phase 1.

---

## 1. Purpose

ShareGrid is a peer-to-peer compute-sharing network that allows participants to host and consume local LLM inference without relying on cloud providers. The system is designed around three roles: a router that coordinates the network, hosts that provide compute, and users that consume it.

---

## 2. Core Components

| Component | Role |
|-----------|------|
| **LLMRouter** | Network backbone. Maintains registries of active hosts and users. Issues authentication keys. Brokers initial connections. |
| **LLMHost** | Compute provider. Runs a local LLM inside a hardened Docker container. Accepts only router-authenticated sessions. |
| **LLMUser** | Consumer interface. CLI that queries the router for available hosts, then opens a direct encrypted channel to the chosen host. |

---

## 3. High-Level System Diagram

```mermaid
graph TB
    subgraph User Machine
        U[LLMUser<br/>CLI Interface]
    end

    subgraph Router Infrastructure
        R[LLMRouter<br/>Registry + Auth]
    end

    subgraph Host Machine
        subgraph Docker Container hardened
            LLM[LLM Model]
            H[LLMHost<br/>API Adapter]
        end
    end

    U -- "1. Register / Handshake (TLS)" --> R
    R -- "2. Host list + session token" --> U
    H -- "A. Register + receive host key (TLS)" --> R
    R -- "B. Host key (auth token)" --> H
    U -- "3. Direct encrypted session (TLS + host key)" --> H
    H -- "4. LLM responses" --> U
```

---

## 4. Registration and Session Flows

### 4.1 LLMHost Registration

```mermaid
sequenceDiagram
    participant H as LLMHost
    participant R as LLMRouter
    participant D as Docker Container

    H->>D: Start hardened container with LLM
    D-->>H: Container ready, port exposed
    H->>R: Connect + register (TLS)<br/>Send: host metadata, model info, endpoint
    R->>R: Validate registration<br/>Add to host registry
    R-->>H: Issue host key (signed token)
    H->>H: Store host key<br/>Only accept sessions presenting this key

    loop Heartbeat
        H->>R: Heartbeat ping
        R->>R: Update last-seen timestamp
    end

    note over R: If heartbeat times out,<br/>host is removed from registry
```

### 4.2 LLMUser Session Flow

```mermaid
sequenceDiagram
    participant U as LLMUser CLI
    participant R as LLMRouter
    participant H as LLMHost

    U->>R: Connect + handshake (TLS)
    R->>R: Authenticate user session
    R-->>U: List of available hosts<br/>(metadata: model, endpoint, host key)

    U->>U: User selects host from CLI

    U->>H: Open direct encrypted connection<br/>Present host key as session credential
    H->>H: Validate host key
    H-->>U: Session established

    loop Conversation
        U->>H: Prompt (encrypted)
        H->>H: LLM inference inside container
        H-->>U: Response (encrypted)
    end

    U->>H: Close session
    H->>H: Tear down session state<br/>No state persists between sessions
    U->>R: Session ended
    R->>R: Update user registry
```

---

## 5. Security Model

Security is a first-class concern. The threat model covers both the host side (protecting the host machine from the LLM and from users) and the user side (protecting the user from a malicious host).

### 5.1 Threat Model Summary

| Threat | Mitigation |
|--------|------------|
| Malicious actor posing as a legitimate LLMHost | Router-issued host keys; hosts must re-register and re-prove identity on reconnect |
| Eavesdropping on User ↔ Host traffic | All User ↔ Host communication is a direct, encrypted TLS channel |
| LLM or host process accessing the host machine | Hardened Docker container with no volume mounts, no host networking, no host IPC |
| LLM output containing malware targeting the user | Phase 1: output is plain text only — no execution, no file writes on user machine |
| Information leaking between sessions on the same host | Session state is explicitly torn down after each session; container is stateless across sessions |
| Host LLM used as internet proxy | Phase 1: no internet access configured in container |

### 5.2 Security Architecture Diagram

```mermaid
graph LR
    subgraph LLMHost Machine
        subgraph Docker hardened
            LLM[LLM Process]
            API[Host API]
        end
        OS[Host OS / Filesystem]
    end

    subgraph LLMUser Machine
        CLI[LLMUser CLI]
        UFS[User Filesystem]
    end

    CLI -- "TLS encrypted" --> API
    API --> LLM
    LLM -. "blocked: no host access" .- OS
    LLM -. "blocked: no internet" .- WWW((Internet))
    API -. "blocked: no file write" .- UFS

    style OS fill:#fdd,stroke:#f00
    style UFS fill:#fdd,stroke:#f00
    style WWW fill:#fdd,stroke:#f00
```

### 5.3 Docker Hardening Requirements (Phase 1)

The Docker container running the LLM must be configured with:

- No volume mounts to the host filesystem
- No host network mode (use isolated bridge network with a single exposed inference port)
- No IPC sharing with host
- Drop all Linux capabilities not required for inference
- Read-only root filesystem where possible
- No privileged mode

---

## 6. Component Responsibilities (Phase 1)

### LLMRouter

- Maintains an in-memory registry of connected LLMHosts and their metadata (model name, endpoint address, host key)
- Maintains an in-memory registry of active LLMUser sessions
- Issues signed host keys to LLMHosts on registration
- Authenticates LLMUsers and returns the current host list
- Removes hosts that stop heartbeating; removes users that become inactive
- Does **not** proxy or observe User ↔ Host traffic

### LLMHost

- Starts and manages the hardened Docker container containing the LLM
- Registers with the configured LLMRouter on startup
- Stores the router-issued host key and enforces it on all incoming connections
- Accepts one session at a time (Phase 1 constraint)
- Tears down all session state on session end

### LLMUser

- CLI interface; no GUI in Phase 1
- Connects to the configured LLMRouter on startup
- Presents the user with a list of available hosts and their model metadata
- Opens a direct TLS connection to the selected LLMHost
- Sends prompts and displays responses; no local file I/O or command execution in Phase 1

---

## 7. Data Flow Summary

```mermaid
flowchart TD
    A([LLMHost starts]) --> B[Register with LLMRouter\nReceive host key]
    C([LLMUser starts]) --> D[Connect to LLMRouter\nReceive host list]
    D --> E{User selects host}
    E --> F[Open direct TLS session to LLMHost\nPresent host key]
    F --> G[Send prompt]
    G --> H[LLM inference in container]
    H --> I[Return response to LLMUser]
    I --> J{Continue?}
    J -- Yes --> G
    J -- No --> K[Close session\nTear down state]
```

---

## 8. Phase Roadmap — Architectural Impact

The following table summarises how later phases extend the architecture. These concerns shape some Phase 1 design decisions (e.g. keeping the router stateless about conversation content, and keeping the User ↔ Host channel independent of the router).

| Phase | Addition | Architectural Impact |
|-------|----------|----------------------|
| **1** | MVP: 1 host, 1 router, 1 user. CLI only. No internet. No execution. | Baseline architecture described in this document. |
| **2** | OpenCode provider integration. Local file/command execution on user machine with sandboxing. | LLMUser gains a sandboxed execution layer. Host responses may carry structured tool-call payloads. |
| **3** | Controlled internet access for LLMHost. | Docker container gains a filtered egress proxy. Router or a separate policy service controls allowed domains. |
| **4** | Multiple hosts and users. Session reservation (1 user per host per session). | Router gains session-state tracking and host-availability logic. Hosts must signal busy/free status. |
| **Future** | Multiple routers, load balancing, resource accounting, model-selection assistant. | Router becomes a distributed or federated service. Adds resource metering and request classification layers. |

---

## 9. Key Design Decisions and Rationale

**Direct User ↔ Host connection (no router proxy)**
The router only brokers the initial handshake. All inference traffic flows directly between user and host. This keeps the router lightweight and prevents it from becoming a bottleneck or a privacy risk as the network grows.

**Router-issued host keys**
Rather than a full PKI in Phase 1, the router issues a signed token to each host on registration. The user receives this token in the host list and presents it when opening a session. This allows the host to verify that the connecting user has been through the router without the router needing to be online during the session.

**Stateless session teardown**
The LLMHost destroys all session context after a session ends. This is a security requirement to prevent cross-session information leakage, and is foundational for Phase 4's multi-user model.

**CLI-only interface in Phase 1**
Removes the attack surface of a local web server or file system access. Phase 2 introduces execution capabilities, which will require their own sandboxing design.
