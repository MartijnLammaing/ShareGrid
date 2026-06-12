# Branch: lan-default-networking

Goal: make LAN/IPv4 the default inter-module connection. Modules reach each other
via the host machine's LAN IPv4 + published port (no shared Docker bridge).

## Remaining
- [ ] Two-machine LAN smoke test (router/host/user on separate machines) — manual,
      requires real hardware; not runnable in this environment.
- [ ] Single-box start-dev.sh end-to-end via LAN IP — manual (needs Docker + model).

## Pre-existing test failures (NOT introduced by this branch — flag to maintainer)
- sharegrid-router tests/integration/host-list.test.ts: 2 roleKey-rejection tests
  assert `userSock.destroyed` after the router closes the user socket. These fail on
  the base commit independently of networking (socket teardown timing). Left untouched.
- sharegrid-router lint: 3 pre-existing eslint errors in tests/integration/registration.test.ts
  and tests/unit/tls-listener.test.ts (unused var / explicit any). Present on base.

## Done (A–D)
- A. sharegrid-host: removed detectListenHost (bridge-IP/ipify/IPv6); SHAREGRID_LISTEN_HOST
     now required IPv4; docker-run.sh auto-detects + injects it; dropped --network sharegrid-net.
     Unit + integration green.
- B. sharegrid-router: startup-banner advertises injected SHAREGRID_LAN_IPS (IPv4 only),
     removed public-IP/interface-enum/IPv6; docker-run.sh auto-detects + injects, no sharegrid-net.
     Banner tests rewritten; fixed pre-existing listenHost test omissions (6 of 8 integration
     failures resolved as a side effect).
- C. sharegrid-user: dropped --network sharegrid-net (CLI + server). Tests green.
- D. Parent: start-dev.sh LAN header + obsolete-network cleanup; updated architecture_overview.md,
     architecture_llmrouter.md (§6/§7), architecture_llmhost.md (§2/§5.3); router README + examples.
