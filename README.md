# camoufox-multi

CLI tool for managing isolated browser sessions using [Camoufox](https://github.com/daijro/camoufox) (anti-detect Firefox) inside Docker containers. Each account gets its own proxy, persistent Firefox profile, fingerprint seed, and virtual display — accessible via noVNC in the browser.

## Requirements

- Docker + Docker Compose
- `make`

## Quick start

```bash
# Build the image once (or after Dockerfile changes)
make build

# Create a new account (interactive wizard)
make new

# Start the account
make up ACCOUNT=account-1

# Open in browser
open http://localhost:<PORT>/vnc.html
```

## Commands

| Command | Description |
|---------|-------------|
| `make build` | Build Docker image |
| `make new` | Interactive account creation wizard |
| `make up ACCOUNT=<name>` | Start container |
| `make down ACCOUNT=<name>` | Stop container |
| `make restart ACCOUNT=<name>` | Restart container |
| `make logs ACCOUNT=<name>` | Follow container logs |
| `make status` | Show running containers with URLs |
| `make list` | All accounts (running + stopped) |
| `make set-proxy ACCOUNT=<name>` | Update proxy without wiping profile |
| `make clean ACCOUNT=<name>` | Wipe Firefox profile only |
| `make remove ACCOUNT=<name>` | Remove container + entire account folder |
| `make check-leaks ACCOUNT=<name>` | Run leak detection inside container |

## Account configuration

Each account lives in `accounts/<name>/.env`:

| Variable | Example | Description |
|----------|---------|-------------|
| `PROXY` | `http://user:pass@host:port` | Proxy URL (http or socks5) |
| `PORT` | `6901` | Host port for noVNC (auto-selected) |
| `VNC_PW` | `abc123xyz` | VNC password |
| `CAM_OS` | `windows` / `macos` / `linux` | OS fingerprint spoofed by Camoufox |
| `CAM_SEED` | `1234567890` | Stable fingerprint seed (random per account) |
| `CAM_SCREEN` | `1280x720` | Virtual screen resolution (WxH) |
| `TZ` | `Europe/Berlin` | Container timezone (auto-detected from proxy) |
| `HOMEPAGE` | `https://ipleak.net` | First page opened on start |

## Architecture

### Container startup sequence

1. **`setup-proxy.sh`** runs as root — configures `redsocks` + `iptables` transparent proxy
2. **Xvfb** starts with resolution `CAM_SCREEN + 200px` margin (ensures the full Firefox window fits in noVNC)
3. **x11vnc** + **websockify** expose the virtual display as noVNC on port 6901
4. **`browser.py`** drops root via `gosu` and launches Camoufox as an unprivileged user

### Network-level proxy isolation

The core isolation mechanism does **not** rely on the browser's built-in proxy setting alone:

- Resolves proxy hostname to IP **before** iptables rules are applied
- Starts `redsocks` (transparent SOCKS/HTTP proxy daemon on `127.0.0.1:12345`)
- Redirects all outbound TCP → redsocks → proxy via an iptables `REDSOCKS` chain
- Excludes private IP ranges and the proxy IP itself to prevent routing loops
- **Drops all DNS (UDP/TCP port 53)** to prevent DNS leaks — DNS is resolved inside the proxy tunnel
- Requires `cap_add: NET_ADMIN` in docker-compose.yml

### Fingerprint protection

| Layer | What it does |
|-------|-------------|
| Camoufox | Patches canvas, WebGL strings, navigator, User-Agent; disables WebRTC |
| `geoip=True` | Aligns timezone and locale to proxy IP automatically |
| `CAM_SEED` | Derives stable per-account offsets for canvas noise, font spacing, AudioContext sample rate |
| `CAM_SCREEN` | Sets virtual screen dimensions reported to the browser |
| Windows fonts | Microsoft core fonts installed in image for realistic font enumeration |
| Network proxy | All TCP (not just browser traffic) is routed through the proxy |

### Screen size

`CAM_SCREEN` (e.g. `1280x720`) controls two things:

- The screen dimensions reported to the browser via `browserforge.fingerprints.Screen`
- The Xvfb virtual display resolution (set to `CAM_SCREEN + 200px` on each axis to ensure the complete Firefox window is always visible in noVNC)

### noVNC access

noVNC is bound to `127.0.0.1` only — not exposed on LAN. Access at `http://localhost:<PORT>/vnc.html`.

## Security audit (Claude Code)

If you use [Claude Code](https://claude.ai/code), you can run a full privacy and security audit of your accounts directly from the CLI:

```
/camoufox-audit
```

The skill reads all relevant scripts and config, then checks for proxy leaks, DNS leaks, WebRTC exposure, fingerprint uniqueness across accounts, bot-detection signals, and whether accounts can be linked to each other or to the host machine. It produces a structured report with findings and recommendations.

## Account data layout

```
accounts/<name>/
├── .env       # Account config (proxy, port, fingerprint settings)
├── profile/   # Persistent Firefox profile (mounted → /home/user/.mozilla)
└── files/     # Shared folder for uploading files into the browser (mounted → /home/user/files)
```

To make a file accessible inside the browser, copy it into `accounts/<name>/files/` and open it via:

```
file:///home/user/files/<filename>
```
