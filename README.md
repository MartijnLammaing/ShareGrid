# ShareGrid

Peer-to-peer compute-sharing for closed groups of trusted actors. Run local LLM inference across your team's machines — no cloud provider required.

ShareGrid connects hosts running local LLMs with users who want to consume them, all within a private network you control. The group administrator runs a router that brokers connections; after the initial handshake, all inference traffic flows directly between user and host over an encrypted TLS channel.

## Components

| Module | Role |
|--------|------|
| [sharegrid-router](sharegrid-router/) | Network backbone — maintains host registry, issues auth tokens, brokers initial connections |
| [sharegrid-host](sharegrid-host/) | Compute provider — runs an LLM inside a hardened container (Docker or macOS native) |
| [sharegrid-user](sharegrid-user/) | Consumer interface — OpenAI-compatible HTTP server for OpenCode, or standalone interactive CLI |

## Quick Start

Start a full local network (router + host + interactive CLI) in one command:

```sh
./start-dev.sh
```

This builds all three modules, starts the router and host as background containers, then drops you into an interactive chat session. Exit the CLI with `Ctrl+D` — the router and host keep running.

Other modes:

```sh
./start-dev.sh --server        # all three as background containers; user exposes OpenAI API on port 3000
./start-dev.sh --macos-host    # run the host natively on Apple Silicon (Metal GPU acceleration)
./start-dev.sh --no-build      # skip rebuilding images
```

## How It Works

1. **Host registers** — a host machine connects to the router, advertises its model, and receives a signed authentication token.
2. **User connects** — a user connects to the router to get the list of available hosts, then opens a direct encrypted session to their chosen host.
3. **Inference flows directly** — all prompt/response traffic goes straight between user and host. The router plays no further role.

For the deep dive, see [architecture_overview.md](docs/architecture_overview.md).

## Security

ShareGrid is designed for closed groups — trust is established out-of-band by the group administrator. Each connection uses TLS with certificate fingerprint pinning, and the router issues two separate URLs (one for hosts, one for users) so roles cannot be forged.

See [architecture_overview.md §5](docs/architecture_overview.md#5-security-model) for the full threat model and security architecture.

## Development

Each module is an independent git submodule with its own `package.json`:

```sh
cd sharegrid-router   # or sharegrid-host / sharegrid-user
npm install
npm run dev
```

Run `./start-dev.sh` from the root to exercise the full stack locally. Each submodule's README has module-specific configuration and source documentation.

## Network Modes

- **LAN (default)** — modules connect over IPv4 on the local network
- **Internet** — modules connect over globally-routable IPv6; set `SHAREGRID_NETWORK_MODE=internet`

See [architecture_overview.md §9](docs/architecture_overview.md#9-key-design-decisions-and-rationale) for details.
