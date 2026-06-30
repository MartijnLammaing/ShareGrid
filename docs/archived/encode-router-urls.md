# BG-1 — Encode router URLs for easy copy-paste

## Business Summary

Operators must copy-paste router URLs containing special characters (`?`, `&`, `=`, `:`, `[]`) between terminals and chat apps. These characters are frequently mangled by terminals, copy-paste buffers, and message formatting — leading to broken URLs and failed connections.

By base64-encoding the `SHAREGRID_HOST_ROUTER_URL` and `SHAREGRID_USER_ROUTER_URL` tokens printed by the router's `docker-run.sh`, operators copy a single alphanumeric string with no special characters. The host and user startup scripts transparently decode it back to the raw URL before use.

**Result:** Zero-copy-paste errors for operators distributing URLs to hosts and users.

## Architecture Impact

**None.** This is a shell-layer convenience with no change to the architecture:

- The TypeScript code (`parseFingerprintFromUrl`, `startup-banner.ts`, config validation) receives raw URLs as before — unchanged.
- The encoding/decoding happens entirely at the shell boundary: `sharegrid-router/docker-run.sh` encodes on output; host/user startup scripts decode on input.
- `start-dev.sh` passes the encoded value through — no functional change.
- `parseFingerprintFromUrl` in `sharegrid-shared/src/tls.ts` is untouched.
- No change to the security model, trust boundaries, or URL format.

## Implementation Steps

1. [ ] `sharegrid-router/docker-run.sh` — After extracting `HOST_URL` and `USER_URL` from banner logs (~line 163), base64-encode each with `printf '%s' "$URL" | openssl base64 -A`. Print `SHAREGRID_HOST_ROUTER_URL=<encoded>` and `SHAREGRID_USER_ROUTER_URL=<encoded>`.

2. [ ] `start-dev.sh` — Lines 124-125: change log messages from "Host registration URL: ..." to "Host registration token: ..." (and "User access URL: ..." → "User access token: ..."). The `cut -d= -f2-` extraction on lines 115-116 works unchanged with encoded values.

3. [ ] `sharegrid-host/docker-run.sh` — After the empty-check guard (~line 34), decode: `SHAREGRID_ROUTER_URL=$(printf '%s' "$SHAREGRID_ROUTER_URL" | openssl base64 -A -d)`. Existing mode check (~line 41) and container pass-through (~line 141) use decoded value automatically.

4. [ ] `sharegrid-host/macos-native/macos-run.sh` — Same decode step after the empty-check guard (~line 37). Mode check (~line 44) and export (~line 145) use decoded value.

5. [ ] `sharegrid-user/docker-run.sh` — Same decode step after the empty-check guard (~line 38). Container pass-through (~lines 66, 80) use decoded value.

6. [ ] `sharegrid-host/docker-run.example.sh` — Replace raw URL example with a base64-encoded one. Add comment: "Base64-encoded router URL — copy the SHAREGRID_HOST_ROUTER_URL value from the router's startup output."

7. [ ] `sharegrid-user/docker-run.example.sh` — Same treatment.

8. [ ] Verify — Run `start-dev.sh` locally; confirm host registers and user connects. Test both `lan` and `internet` mode.
