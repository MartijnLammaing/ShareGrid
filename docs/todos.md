# Branch: fix/submodule-shared-realignment

Eliminate nested-submodule version skew so every clone reproducibly builds.
Root cause of `parseEndpoint is not a function`: stale nested `sharegrid-shared`
checkouts + drifted superproject gitlinks. Target shared `main` tip: c185631.

## Tasks

- [x] Bump router nested shared -> c185631; verified (typecheck + esbuild + docker build + banner smoke test); committed a971d4c
- [x] Bump user nested shared -> c185631; verified (typecheck + esbuild + docker build); committed 2fd6e2d
- [ ] BLOCKED — Bump host nested shared -> c185631.
      The bump itself is correct & necessary (host code at 799fb24 imports `NetworkMode`/`ParsedRouterUrl.mode`
      which only exist in new shared). BUT host has a SEPARATE pre-existing bug unrelated to shared:
      `src/index.ts:37,39` use `config.SHAREGRID_MODELS_DIR`, while `src/config.ts:40-41` define
      `SHAREGRID_MODEL_FILE` / `SHAREGRID_MODEL_PATH` (no MODELS_DIR). This is the half-finished
      auto-detect-models feature. Host won't typecheck/build until that is fixed.
      DECISION NEEDED from user: fix host auto-detect-models config bug (out of original scope)? then bump+commit.
- [ ] Push module branches; open a PR per module repo
- [ ] Realign superproject gitlinks (git add the 3 modules); commit; confirm clean `git status`
- [ ] Verify clean-clone reproducibility: fresh recurse-submodules clone + router docker build banner
- [ ] Document other-machine unblock: `git submodule update --init --recursive --force` + rebuild
