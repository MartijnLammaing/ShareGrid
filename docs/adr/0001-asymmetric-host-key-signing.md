# ADR-0001: Asymmetric Signing for Host Key Issuance

## Status

Accepted

## Date

2026-05-12

## Context

When a LLMHost registers with the LLMRouter, the router issues a **host key** — a token the host uses to authenticate incoming LLMUser sessions. A LLMUser presents this token when opening a session; the LLMHost validates it before allowing any inference traffic.

Two approaches were considered:

**Option A — Symmetric HMAC**
The router and each host share a secret. The router HMACs the token with that secret; the host verifies with the same secret. Simple to implement. However, every host must hold a copy of the shared secret (or a per-host secret that the router also stores). In a single-router, single-host network (Phase 1) this is manageable, but it scales poorly:

- Adding multiple routers (planned post-Phase 4) requires every router to share every host's secret, or requires a centralised secret store — both are operationally complex.
- A compromised host leaks its HMAC key. If a single shared secret is used, the entire network is compromised.

**Option B — Asymmetric signing (Ed25519)**
The router holds a single private signing key. Its corresponding public key is distributed to all LLMHosts at registration time (or pre-configured). The router signs each host key with its private key; hosts verify signatures using the router's public key.

- No secret is held by the host — only a public key. A compromised host reveals nothing that allows token forgery.
- Adding more routers in Phase 4+ only requires distributing their public keys, not sharing secrets.
- Ed25519 signatures are compact (64 bytes), fast to verify, and well-supported across languages.

## Decision

Use **asymmetric signing with Ed25519** for host key issuance.

- The LLMRouter generates an Ed25519 keypair on first start. The private key never leaves the router process.
- The router's Ed25519 **public key** is distributed to LLMHosts as part of the registration handshake (or pre-configured out-of-band for tighter security).
- The host key issued to a LLMHost is a signed payload containing at minimum: host identifier, issue timestamp, expiry timestamp. The signature is produced with the router's Ed25519 private key.
- The LLMHost verifies incoming LLMUser session tokens by checking the Ed25519 signature against the router's public key.
- The router's private key is held in memory only during Phase 1; persistence strategy is deferred to a later ADR.

## Consequences

- **Good:** No secrets are stored on LLMHost machines. A compromised host cannot forge tokens.
- **Good:** The same design extends naturally to multiple routers (Phase 4+) — each router has its own keypair; hosts trust a set of known public keys.
- **Good:** Token expiry is encoded in the signed payload, enabling key rotation without a shared-secret synchronisation problem.
- **Bad:** Slightly more implementation complexity than HMAC — requires an Ed25519 library on both router and host.
- **Neutral:** The router's private key becomes a critical secret. Its storage, backup, and rotation must be addressed before production use (out of scope for Phase 1).
