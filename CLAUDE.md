# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

CLI tool for managing isolated browser sessions using Camoufox (anti-detect Firefox) inside Docker containers. Each account has its own proxy, persistent Firefox profile, and fingerprint seed. Access is via noVNC at `http://localhost:<PORT>/vnc.html`.

## Commands

```bash
make build                          # Build Docker image (run once or after Dockerfile changes)
make new                            # Interactive account creation wizard
make up ACCOUNT=account-1           # Start container
make down ACCOUNT=account-1         # Stop container
make restart ACCOUNT=account-1      # Restart container
make logs ACCOUNT=account-1         # Follow logs
make status                         # Show running containers with URLs
make list                           # All accounts (running + stopped)
make set-proxy ACCOUNT=account-1    # Update proxy without wiping profile
make clean ACCOUNT=account-1        # Wipe Firefox profile only
make remove ACCOUNT=account-1       # Remove container + entire account folder
make check-leaks ACCOUNT=account-1  # Run leak detection inside container
```

All account-scoped commands require `ACCOUNT=<name>`. The Makefile reads `accounts/<name>/.env` and calls `docker compose --env-file` with it.

## Architecture

### Container startup sequence (`scripts/start.sh`)
1. `setup-proxy.sh` runs **as root** — configures redsocks + iptables transparent proxy
2. Xvfb starts at `CAM_SCREEN + 200px` on each axis (margin ensures full Firefox window fits in noVNC)
3. x11vnc + websockify expose the virtual display as noVNC on port 6901
4. `gosu user python /scripts/browser.py` — drops root, launches Camoufox as unprivileged user

### Network-level proxy isolation (`scripts/setup-proxy.sh`)
This is the core security mechanism. Does **not** rely on the browser's proxy setting alone:
- Parses `PROXY` env, resolves hostname to IP **before** iptables is configured
- Starts `redsocks` (transparent SOCKS/HTTP proxy daemon on `127.0.0.1:12345`)
- Creates iptables `REDSOCKS` chain that redirects all outbound TCP → redsocks → proxy
- Excludes private ranges and the proxy IP itself to avoid routing loops
- **Drops all UDP/TCP port 53** to prevent DNS leaks
- Requires `cap_add: NET_ADMIN` in docker-compose.yml

### Account data layout
```
accounts/<name>/
├── .env       # All config: PROXY, PORT, VNC_PW, CAM_OS, CAM_SEED, CAM_SCREEN, TZ, HOMEPAGE
└── profile/   # Persistent Firefox profile (mounted → /home/user/.mozilla)
```

### `.env` variables
| Variable | Purpose |
|----------|---------|
| `PROXY` | Full proxy URL: `http://user:pass@host:port` or `socks5://host:port` |
| `PORT` | Host port for noVNC (auto-selected from 6901+) |
| `VNC_PW` | VNC password (random 12 chars by default) |
| `CAM_OS` | Camoufox OS fingerprint: `windows` / `macos` (linux not supported by browserforge) |
| `CAM_SEED` | Stable per-account fingerprint seed (random uint32, derived into canvas/font/audio offsets) |
| `CAM_SCREEN` | Virtual screen resolution in `WxH` format, e.g. `1280x720` |
| `TZ` | Container timezone (auto-detected from proxy geolocation) |
| `HOMEPAGE` | First page opened on start |

### Fingerprint protection layers
- **Camoufox** — patches canvas, WebGL strings, navigator, UA, disables WebRTC
- **`geoip=True`** — timezone/locale aligned to proxy IP automatically
- **`CAM_SEED`** — derives stable per-account offsets for canvas noise (`canvas:aaOffset`), font spacing (`fonts:spacing_seed`), AudioContext sample rate
- **`CAM_SCREEN`** — sets screen dimensions reported to the browser via `browserforge.fingerprints.Screen`
- **Windows fonts** installed in image — realistic font enumeration fingerprint
- **Network-level proxy** — all TCP (not just browser) goes through proxy; direct connections are impossible

### Port binding
noVNC is bound to `127.0.0.1` only (`"127.0.0.1:${PORT}:6901"`). Not exposed on LAN.

## Language

All code comments, file content, commit messages, and documentation must be written in **English only**, regardless of the language used in the conversation.