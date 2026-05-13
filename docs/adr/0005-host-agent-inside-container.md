# ADR-0005: Run all host agent logic inside the Docker container

## Status
Accepted

## Date
2026-05-12

## Context
The previous architecture split LLMHost into a Host Agent on the host OS and a Docker container running llama.cpp. This required a bind-mounted Unix socket (an exception to the no-volume-mount hardening rule) and a non-trivial Container Manager component. The host operator had to run and maintain two separate processes.

## Decision
Move the Router Client, Session Manager, and Inference Proxy inside the Docker container alongside llama.cpp. The Unix socket between the Inference Proxy and llama.cpp is now fully internal — no bind mount needed. The host operator's only action is a single `docker run`. On startup, the container generates an ephemeral TLS keypair and registers with the router; all keys are held in memory only. A container restart means full re-registration as a new host.

## Consequences
- Good: No bind mounts; no host-side agent process; single deployable unit.
- Bad: Container failure takes down the session manager and router client together; the host disappears from the registry until Docker restarts it and it re-registers.
