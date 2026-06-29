# Phase 4 — macOS Native Deployment Completion Summary

> **Status: Complete.** 26 planned tasks across sub-phases 4.0 through 4.3 are shipped and merged to `main`.

> **For agents:** The archived implementation plan linked at the [bottom of this file](#archived-implementation-plans)
> is a historical task-level build record. **Do not open it during normal operation** — it contains no
> actionable information for future phases. Consult it only if explicitly instructed to investigate
> Phase 4 build history.

---

## Overview

Phase 4 adds an Apple Silicon native deployment mode to LLMHost. Instead of relying on Docker, hosts can
now build `llama-server` with Metal GPU acceleration and run it under macOS's `sandbox-exec` for hardening.
The Node.js application code is unchanged; only the launch path differs.

All Phase 4 work lives in the `sharegrid-host` repository plus the parent mono-repo's `start-dev.sh`:

| Repository | Final commit | Role |
|---|---|---|
| `sharegrid-host` | `788d14e` | Native build scripts, configurable binary path, sandbox-exec integration, Metal GPU support |
| Parent repo | `e3c5df4` | `--macos-host` flag in `start-dev.sh` for local dev; follow-up fix for user image build |

---

## LLMHost — `sharegrid-host`

macOS native deployment mode. 26 tasks total across four sub-phases.

### Sub-phase 4.0 — `LLAMA_TAG` + Dockerfile refactor

Single source of truth for the pinned `llama.cpp` git tag.

- **`LLAMA_TAG`** — new file at repo root containing only the tag string (e.g. `b9371`).
- **`Dockerfile`** — Stage 1 reads the tag via `COPY LLAMA_TAG .` instead of hardcoding `--branch`.
- **`.gitignore`** — confirmed `LLAMA_TAG` is committed.
- Docker image builds and runs correctly with the refactored Dockerfile.

### Sub-phase 4.1 — Source changes

Make the `llama-server` binary path and sandbox profile configurable at runtime.

- **`src/config.ts`** — added `SHAREGRID_LLAMA_BINARY` (default: `/app/llama-server`) and `SHAREGRID_SANDBOX_PROFILE` (optional).
- **`src/llama-launcher.ts`** — replaced hardcoded binary path; when `sandboxProfilePath` is set, spawns via `sandbox-exec -f <profile> -D LLAMA_BINARY=<path> -D MODELS_DIR=<dir> <binary> <args>`.
- **`src/index.ts`** — wires new config values into `launchLlama`.
- **Unit tests** — updated config and llama-launcher tests; full CI gate passes.

### Sub-phase 4.2 — `macos-native/` directory

Four files for the native launch path:

- **`setup.sh`** — builds `llama-server` with Metal from the pinned `LLAMA_TAG` tag. Handles guards (arm64, cmake, git, Xcode CLT), `--check` mode, and idempotent builds.
- **`sandbox.sb`** — SBPL profile that permits Metal/IOKit, model file access, and `/tmp`, while blocking filesystem and network.
- **`macos-run.sh`** — native launch script with env var export, IP detection, shared build, and restart-on-failure loop.
- **`README.md`** — operator instructions: prerequisites, setup steps, env vars, troubleshooting.

### Sub-phase 4.3 — Integration testing (manual)

All eight manual checks verified on an Apple M2:

- `setup.sh` builds clean with Metal support (`ggml_metal_init` confirmed).
- Sandbox permits Metal, blocks filesystem (`/etc/passwd`) and network (`curl`).
- Full session works end-to-end: registration → inference → teardown with KV slot release.
- Node process restarts within ~2 s on forced kill.
- Docker path unaffected — no regressions.

---

## Parent Repository — `ShareGrid`

- **`start-dev.sh`** — added `--macos-host` flag that runs the host natively (Metal + sandbox-exec) instead of inside Docker, while the router and user remain in their Docker containers.
- **Follow-up fix** — ensured `sharegrid-user` image is built in `--macos-host` CLI mode (PR #28, commit `861e14f`).
- Architecture documents updated to reflect Phase 4 design decisions.

---

## Archived Implementation Plans

> **Agents: do not open the file linked below unless explicitly instructed.**
> It is a historical task-level record of the Phase 4 build process and contains
> no actionable information for future phases. All relevant design decisions are
> captured in the architecture documents (`architecture_overview.md`,
> `architecture_llmhost.md`).

| Component | Archived plan |
|-----------|--------------|
| LLMHost | [`archived/phase_4/implementation_plan_llmhost.md`](archived/phase_4/implementation_plan_llmhost.md) |
