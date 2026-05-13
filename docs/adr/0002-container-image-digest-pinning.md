# ADR-0002: Container image integrity verification via digest pinning

## Status
Accepted

## Date
2026-05-12

## Context
The LLMHost runs a container image that includes the LLM inference server. A tag-based pull gives no integrity guarantee — the image behind a tag can be silently replaced.

## Decision
Pin the container image by `sha256` digest in the LLMHost configuration. Docker enforces the check natively before the container starts; the Host Agent fails fatally if the digest does not match and must not fall back to a tag-based pull. Provenance verification (e.g. Sigstore/cosign) is deferred to a later phase.

## Consequences
- Good: Image updates are deliberate and auditable; no custom verification code required.
- Bad: Does not verify provenance — a digest-pinned image can still be malicious if the attacker controlled the original build.
