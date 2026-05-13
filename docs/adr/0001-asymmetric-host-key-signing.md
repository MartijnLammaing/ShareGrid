# ADR-0001: Asymmetric signing for host key issuance

## Status
Accepted

## Date
2026-05-12

## Context
When a LLMHost registers with the LLMRouter, the router issues a host key — a token the host uses to authenticate incoming LLMUser sessions. A symmetric HMAC approach requires the secret to be held on every host, meaning a single compromised host can forge tokens for the entire network.

## Decision
Use Ed25519 asymmetric signing. The router holds the private key; hosts receive only the router's public key and use it to verify session tokens. Token expiry is embedded in the signed payload, enabling rotation without shared-secret synchronisation.

## Consequences
- Good: A compromised host cannot forge tokens — it holds no secret material.
- Good: Extends naturally to multiple routers; hosts trust a set of known public keys.
- Bad: The router's private key is a critical secret; storage and rotation strategy is deferred.
