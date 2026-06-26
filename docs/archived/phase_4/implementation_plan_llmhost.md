# LLMHost — Phase 4 Implementation Plan

> **Scope:** Phase 4 — macOS native deployment mode with Metal GPU acceleration. Companion to [`architecture_llmhost.md`](./architecture_llmhost.md), [`architecture_overview.md`](./architecture_overview.md), and [`implementation_guidelines.md`](./implementation_guidelines.md). This document breaks the Phase 4 LLMHost changes into small, agent-sized tasks.
>
> **Prerequisite:** Phase 3 must be fully merged to `main` in all four repositories.

---

## How to use this document

1. Tasks are grouped into sub-phases. Each task is intentionally small: one file, one clear contract, one verifiable outcome.
2. Each task has a **Status** field. When a task is complete, update its status and the summary ledger at the bottom.
3. Complete sub-phases in order.

### Status legend

| Symbol | Meaning |
|--------|---------|
| `[ ]` | Not started |
| `[~]` | In progress |
| `[x]` | Complete (merged, CI green) |
| `[!]` | Blocked — see notes |

---

## Phase overview

| Sub-phase | Title | Tasks | Depends on |
|-----------|-------|:-----:|------------|
| 4.0 | `LLAMA_TAG` + Dockerfile refactor | 4 | Phase 3 merged to `main` |
| 4.1 | Source changes | 10 | Sub-phase 4.0 merged |
| 4.2 | `macos-native/` directory | 4 | Sub-phase 4.1 merged |
| 4.3 | Integration testing (manual) | 8 | Sub-phase 4.2 merged |

---

## Sub-phase 4.0 — `LLAMA_TAG` + Dockerfile refactor

Create a single source of truth for the pinned `llama.cpp` git tag at `sharegrid-host/LLAMA_TAG`. The Dockerfile Stage 1 reads it instead of hardcoding the tag. No behaviour change.

| # | Task | File | Status |
|---|------|------|:------:|
| H4-1 | Create `LLAMA_TAG` at the `sharegrid-host/` repo root containing only the tag string on a single line with no trailing newline (e.g. `b9371`). | `LLAMA_TAG` | `[x]` |
| H4-2 | Update `sharegrid-host/Dockerfile` Stage 1: add `COPY LLAMA_TAG .` before the `RUN git clone` step; change the clone line to `RUN tag=$(cat LLAMA_TAG) && git clone --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp /src/llama.cpp`. Remove the hardcoded `--branch <tag>`. | `Dockerfile` | `[x]` |
| H4-3 | Confirm `LLAMA_TAG` is **not** ignored by `.gitignore` — it must be committed. No edit needed if absent. | `.gitignore` | `[x]` |
| H4-4 | Build the Docker image locally and confirm it still builds successfully: `docker build -t sharegrid-host .` in `sharegrid-host/`. Verify Stage 1 reads the tag correctly. | CI / local | `[x]` |

---

## Sub-phase 4.1 — Source changes

Make the `llama-server` binary path and the SBPL sandbox profile path configurable at runtime. No changes to session, protocol, or TLS logic.

The architecture document updates listed in `phase_4_plan.md` §4 are applied as the first commit on this branch.

### 4.1.1 Configuration (`src/config.ts`)

| # | Task | File | Status |
|---|------|------|:------:|
| H4-5 | Add `SHAREGRID_LLAMA_BINARY: z.string().min(1).default('/app/llama-server')` to `ConfigSchema`. | `src/config.ts` | `[x]` |
| H4-6 | Add `SHAREGRID_SANDBOX_PROFILE: z.string().min(1).optional()` to `ConfigSchema` — value is `undefined` when absent. | `src/config.ts` | `[x]` |
| H4-7 | Update the two `SHAREGRID_LISTEN_HOST` error messages: replace `"set by docker-run.sh"` with `"set by the launch script (docker-run.sh or macos-run.sh)"`. | `src/config.ts` | `[x]` |
| H4-8 | Update the exported `Config` type to include `SHAREGRID_LLAMA_BINARY: string` and `SHAREGRID_SANDBOX_PROFILE: string \| undefined`. | `src/config.ts` | `[x]` |

### 4.1.2 Llama launcher (`src/llama-launcher.ts`)

| # | Task | File | Status |
|---|------|------|:------:|
| H4-9 | Add `llamaBinary: string` and `sandboxProfilePath: string \| undefined` to the `deps` parameter type of `launchLlama`. | `src/llama-launcher.ts` | `[x]` |
| H4-10 | Replace the hardcoded `LLAMA_BINARY` constant with the `llamaBinary` dep value. When `sandboxProfilePath` is set, spawn: `sandbox-exec -f <sandboxProfilePath> -D LLAMA_BINARY=<llamaBinary> -D MODELS_DIR=<path.dirname(activeModelPath)> <llamaBinary> <...llamaArgs>`. When `sandboxProfilePath` is `undefined`, spawn `<llamaBinary>` directly (existing code path, no behaviour change). Import `path` from `node:path` for `dirname`. | `src/llama-launcher.ts` | `[x]` |

### 4.1.3 Startup wiring (`src/index.ts`)

| # | Task | File | Status |
|---|------|------|:------:|
| H4-11 | Pass `config.SHAREGRID_LLAMA_BINARY` and `config.SHAREGRID_SANDBOX_PROFILE` to `launchLlama` in the startup sequence. | `src/index.ts` | `[x]` |

### 4.1.4 Unit tests

| # | Task | File | Status |
|---|------|------|:------:|
| H4-12 | Update `tests/unit/config.test.ts`: add cases for `SHAREGRID_LLAMA_BINARY` — defaults to `/app/llama-server` when absent; accepts any non-empty string. Add cases for `SHAREGRID_SANDBOX_PROFILE` — `undefined` when absent; accepts any non-empty string. Run `npm run test:unit`. | `tests/unit/config.test.ts` | `[x]` |
| H4-13 | Update `tests/unit/llama-launcher.test.ts`: when `sandboxProfilePath` is set, assert the spawned command is `sandbox-exec`, the first positional args are `-f <profile>`, followed by `-D LLAMA_BINARY=<path>`, `-D MODELS_DIR=<dir>`, then the binary and its flags. When `sandboxProfilePath` is `undefined`, assert the spawned command is the `llamaBinary` value directly. Mock `spawn`; assert `cmd` and `args[0..3]`. Run `npm run test:unit`. | `tests/unit/llama-launcher.test.ts` | `[x]` |
| H4-14 | Run the full CI gate: `npm run typecheck && npm run lint && npm run test:unit`. Must be clean before merging. | — | `[x]` |

---

## Sub-phase 4.2 — `macos-native/` directory

Introduce the `macos-native/` directory in `sharegrid-host/` with all four files. No application source changes.

### 4.2.1 `macos-native/setup.sh`

| # | Task | File | Status |
|---|------|------|:------:|
| H4-15 | Create `macos-native/setup.sh` that builds `llama-server` with Metal support from the pinned tag. Resolves `HOST_DIR` as the parent of the script directory. Reads `LLAMA_TAG` from `$HOST_DIR/LLAMA_TAG`. Sets `BUILD_DIR=$HOST_DIR/macos-native/.build` and `BIN_DIR=$HOST_DIR/macos-native/bin`. Guards: asserts `uname -m` is `arm64`; checks `cmake`, `git`, and Xcode CLT (`xcode-select -p`). Supports `--check`: if `$BIN_DIR/llama-server` exists, exit 0. Clones with `git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$BUILD_DIR/llama.cpp"` when missing. Configures with `cmake -S "$BUILD_DIR/llama.cpp" -B "$BUILD_DIR/cmake-build" -DGGML_METAL=ON -DGGML_NATIVE=ON -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DBUILD_SHARED_LIBS=OFF`. Builds `llama-server` with `cmake --build "$BUILD_DIR/cmake-build" --target llama-server -j"$(sysctl -n hw.logicalcpu)"`. Installs to `$BIN_DIR/llama-server`. Prints the final binary path on success. Make executable. | `macos-native/setup.sh` | `[x]` |

### 4.2.2 `macos-native/sandbox.sb`

| # | Task | File | Status |
|---|------|------|:------:|
| H4-16 | Create `macos-native/sandbox.sb` with the SBPL profile specified in `phase_4_plan.md` §5.2. Parameterised via `-D LLAMA_BINARY=<path>` and `-D MODELS_DIR=<dir>`. Includes rules for process, system libraries, standard devices, `/private/tmp`, model files, the llama binary, and Metal/IOKit services. | `macos-native/sandbox.sb` | `[x]` |

### 4.2.3 `macos-native/macos-run.sh`

| # | Task | File | Status |
|---|------|------|:------:|
| H4-17 | Create `macos-native/macos-run.sh` as the macOS native launch script. Sets `SCRIPT_DIR` and `HOST_DIR`. Reads `PORT=${SHAREGRID_HOST_PORT:-9000}` and `MODELS_DIR=${SHAREGRID_MODELS_DIR:-$HOST_DIR/models}`. Sets `LLAMA_BINARY=$SCRIPT_DIR/bin/llama-server` and `SANDBOX_PROFILE=$SCRIPT_DIR/sandbox.sb`. Validates `SHAREGRID_ROUTER_URL` is set. Derives `MODE` from the URL (`*mode=internet*` check). Detects/validates `ADVERTISE_IP` by copying `detect_lan_ip()` and `detect_global_ipv6()` verbatim from `docker-run.sh`, with the same override/error behaviour. Checks `node` and `arm64`. Builds `bundle.cjs` if missing via `npm run build`. Runs `setup.sh --check`, then `setup.sh` if the binary is absent. Exports `SHAREGRID_ROUTER_URL`, `SHAREGRID_LISTEN_PORT`, `SHAREGRID_LISTEN_HOST`, `SHAREGRID_MODELS_DIR`, `SHAREGRID_LLAMA_BINARY`, `SHAREGRID_SANDBOX_PROFILE`. Implements the launch retry loop (restarts `node "$HOST_DIR/dist/bundle.cjs"` after 2 s on non-zero exit; exits cleanly on 0). Logs startup. Make executable. | `macos-native/macos-run.sh` | `[x]` |

### 4.2.4 `macos-native/README.md`

| # | Task | File | Status |
|---|------|------|:------:|
| H4-18 | Create `macos-native/README.md` with operator instructions: prerequisites (Apple Silicon macOS, Xcode CLT, cmake, Node.js 22+), step-by-step setup, optional env vars, first-run compile note, troubleshooting (sandbox logs, Metal detection, `SHAREGRID_ADVERTISE_IP`), and the `sandbox-exec` deprecation/security note. | `macos-native/README.md` | `[x]` |

---

## Sub-phase 4.3 — Integration testing (manual)

End-to-end verification on a real M-series Mac. No new automated test files are added; the existing integration suite covers application logic because the macOS native path uses the same `bundle.cjs`.

| # | Check | Pass criteria | Status |
|---|-------|---------------|:------:|
| H4-19 | `setup.sh` builds clean | Binary present at `macos-native/bin/llama-server`; no cmake errors. | `[x]` |
| H4-20 | Metal is used | `llama-server` stdout contains `ggml_metal_init` on startup. | `[x]` |
| H4-21 | Sandbox allows Metal | No sandbox `deny` violations for Metal/IOKit services in system log. | `[x]` |
| H4-22 | Sandbox blocks filesystem | `cat /etc/passwd` from within `sandbox-exec` is denied. | `[x]` |
| H4-23 | Sandbox blocks network | `curl https://example.com` from within `sandbox-exec` is denied. | `[x]` |
| H4-24 | Full session works | `macos-run.sh` → router registration → user session → inference → session close. | `[x]` |
| H4-25 | Restart on failure | Kill the Node.js process; confirm `macos-run.sh` restarts it within 2 s. | `[x]` |
| H4-26 | Docker unaffected | `docker-run.sh` still builds and registers correctly; no regressions. | `[x]` |

**Sandbox iteration procedure:** If H4-21 fails, add the missing `(allow ...)` rules to `sandbox.sb`, document each addition in the PR with the violation log line that triggered it, and re-run H4-20/H4-21. The final `sandbox.sb` in the PR must have a clean violation log for a complete session (model load + at least one inference turn).

---

## Completion ledger

| Sub-phase | Status | Notes |
|-----------|:------:|-------|
| 4.0 — `LLAMA_TAG` + Dockerfile refactor | `[x]` | |
| 4.1 — Source changes | `[x]` | |
| 4.2 — `macos-native/` directory | `[x]` | |
| 4.3 — Integration testing | `[x]` | All checks verified on an Apple M2: Metal init confirmed, no sandbox denials over a full session (`Assistant: Paris`), KV slot released on teardown, and the Node host restarted ~2.07 s after a forced kill. |

---

## Next steps after completion

Once all sub-phases are merged to `main` and the manual test checklist is signed off, create the phase completion summary at `docs/phase_4_summary.md`, update `architecture_llmhost.md` and `architecture_overview.md` with the final changes (already specified in `phase_4_plan.md` §4), and archive this implementation plan to `docs/archived/phase_4/`.
