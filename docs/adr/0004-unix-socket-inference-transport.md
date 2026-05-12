# ADR-0004: Unix Socket for Inference Proxy ↔ Inference Server Transport

## Status

Superseded by [ADR-0005](./0005-host-agent-inside-container.md)

## Date

2026-05-12

## Context

The Inference Proxy (running in the Host Agent process on the host) needs to communicate with the llama.cpp server (running inside the Docker container). Two transport options were evaluated.

**Option A — HTTP on Docker bridge**
The Host Agent connects to the container's internal bridge IP and port over HTTP. Simple to set up; no volume mount required.

Weaknesses:
- The llama.cpp API is reachable by any process on the host machine that knows the bridge IP and port — not just the Host Agent.
- iptables `--uid-owner` rules can restrict access to the Host Agent's UID, but root can flush iptables rules and connect freely.
- Critically, llama.cpp exposes management endpoints beyond `/v1/chat/completions` — in particular `GET /slots`, which returns the full token context of every active session. These endpoints are completely unprotected. Any host process with bridge access can read another user's entire conversation history in real time.
- Filtering at the HTTP endpoint level (to block `GET /slots` etc.) requires a Layer 7 reverse proxy, adding significant complexity.

**Option B — Unix domain socket via bind mount**
llama.cpp listens on a Unix socket file inside the container. The socket directory is bind-mounted from the host, making the socket file accessible to the Host Agent at its host-side path.

- Access is controlled by filesystem permissions. With the socket directory set to `chmod 700`, owned by the Host Agent's OS user, no other non-root process on the host can connect.
- Traffic passes through the kernel directly, never traversing a network interface — there is nothing to sniff with standard network tools.
- Requires a bind mount of a dedicated, empty directory — a targeted relaxation of the no-volume-mount hardening constraint.

**On encryption as a solution**
Adding TLS to the internal channel was considered as a way to protect against host-level eavesdropping. It does not solve the problem: root can read process memory directly (`/proc/<pid>/mem`, `ptrace`), extract in-memory TLS session keys, and access decrypted data regardless of what the transport uses. Encryption protects data in transit from passive sniffing; it does not protect data held in process memory from a privileged local attacker.

**Trust boundary**
Both options share an inherent limitation: a malicious root user on the host machine can access the conversation regardless of transport choice, by reading process memory. This is not a transport-layer problem. It is addressed in the trust boundary statement below.

## Decision

Use a **Unix domain socket** via a dedicated bind-mounted directory.

Implementation requirements:

- The Host Agent creates a dedicated socket directory at startup (e.g. `/run/sharegrid/socket/`), fresh on each run, with `chmod 700` owned by the Host Agent's OS user. No other files are ever placed in this directory.
- The directory is bind-mounted read-write into the container at a fixed internal path (e.g. `/run/sharegrid/socket/`).
- llama.cpp is configured to listen on a Unix socket at that path (e.g. `--host unix:/run/sharegrid/socket/llm.sock`). Unix socket support should be verified against the specific llama.cpp version pinned in ADR-0002; if unavailable, a lightweight in-container bridge (e.g. `socat`) is the fallback.
- Before the Host Agent opens the socket connection, it verifies that the socket file is owned by the UID corresponding to the container's remapped user (established by Docker user namespace remapping). If ownership does not match, startup is aborted.
- On Host Agent shutdown, the socket directory is removed.

## Trust boundary statement

The transport-layer protections in this and related ADRs defend against **non-root host processes** that should not have access to the inference channel. They do not, and cannot, defend against a **malicious LLMHost operator**.

A host operator with root access to their own machine can read process memory, replace binaries, intercept network traffic at the NIC level, and modify the running container. No combination of socket type, filesystem permissions, iptables rules, or encryption of the internal channel closes this gap. Hardware-level isolation (TEE/SGX) would be required, which is out of scope for all current phases.

**ShareGrid's trust model therefore requires that LLMHost operators are trusted participants.** A LLMUser is trusting the host operator in the same way they would trust a cloud provider — legally and socially, not technically. This boundary must be clearly communicated to LLMUsers, and is documented in the system architecture.

## Consequences

- **Good:** The llama.cpp management API (`GET /slots` etc.) is inaccessible to any process other than the Host Agent, without needing iptables or a Layer 7 proxy.
- **Good:** No network interface is used for the internal channel; standard network sniffing tools see nothing.
- **Good:** Access control is simple and auditable — a single directory permission.
- **Bad:** Requires a bind mount — a deliberate, narrow exception to the no-volume-mount hardening rule. The mount exposes only an empty socket directory, not any host data.
- **Bad:** Container's remapped user must be able to write to the mounted directory. The ownership check on the socket file must account for the UID remapping.
- **Neutral:** A malicious root user on the host machine can still access the conversation via process memory. This is a known and accepted limitation documented in the trust boundary statement above.
