# ADR-0002: Container Image Integrity Verification via Digest Pinning

## Status

Accepted

## Date

2026-05-12

## Context

The LLMHost's Container Manager pulls a container image that runs the LLM inference server. If that image is tampered with — either at the registry, in transit, or on disk — the LLMHost could unknowingly run a malicious process with direct access to the inference port. This is a meaningful threat: a corrupted image could exfiltrate conversations, inject content into responses, or attempt container escape.

Two approaches were considered:

**Option A — Digest pinning**
A container image digest (`sha256:…`) is a content-addressed hash of the exact image manifest. Pinning the digest in configuration means the Container Manager requests the image by its exact hash and refuses to run any image that does not match. No registry, proxy, or network path can substitute a different image without detection.

- Simple to implement: one config field, one comparison at pull time.
- No external tooling or PKI required.
- Updating the image requires deliberately updating the pinned digest in config — this is a feature, not a bug: it makes image updates an explicit, auditable action.
- Does not verify *who* published the image, only that the image is byte-for-byte what was configured.

**Option B — Signature verification (e.g. Sigstore/cosign)**
The image publisher signs the image with a private key. The Container Manager verifies the signature with the publisher's public key before running.

- Verifies provenance (who signed it), not just content integrity.
- Requires cosign or equivalent tooling to be present and operational on the host machine.
- Requires the image publisher to maintain a signing key and a signing workflow.
- Adds meaningful operational complexity for Phase 1, where the network is small and participants are trusted.

## Decision

Use **digest pinning** for Phase 1.

- The pinned digest is stored in the LLMHost configuration file (e.g. `image: "registry/image@sha256:<digest>"`).
- The Container Manager passes the digest-qualified image reference directly to the Docker daemon. Docker will refuse to run any image whose content does not match the digest.
- On first run, if the image is not present locally, Docker pulls it by digest — ensuring the pulled image matches before it is ever started.
- The Container Manager must not fall back to a tag-based pull if the digest-qualified pull fails. Failure is fatal; the host does not start.

Signature verification (Option B) is the natural upgrade path if the network grows beyond a trusted group or if image provenance becomes a requirement. That transition does not require changes to the overall architecture — only to the Container Manager's verification step.

## Consequences

- **Good:** Simple to implement and reason about. No external tooling dependencies.
- **Good:** Makes image updates deliberate and auditable — changing the running image requires a config change.
- **Good:** Docker enforces the digest check natively; no custom verification code required.
- **Bad:** Does not verify provenance. A digest-pinned image could still be a malicious image if the attacker controlled the original build or the person who wrote the config.
- **Neutral:** Updating to a new model version requires updating the pinned digest in config and restarting the Host Agent. This is acceptable for Phase 1 where the host operator is also the model curator.
