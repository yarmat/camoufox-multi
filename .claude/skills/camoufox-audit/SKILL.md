---
name: camoufox-audit
disable-model-invocation: true
description: >
  Full privacy/security audit of the Camoufox multi-account browser isolation system.
  Use this skill whenever the user asks about leaks, proxy isolation, fingerprint uniqueness, bot detection, IP exposure,
  kill switch, DNS leaks, WebRTC leaks, or whether accounts can be linked to each other or to the real machine.
  Also trigger for phrases like "check leaks", "audit", "isolation", "fingerprint unique", "bot detection", "proxy leak".
  Always use this skill — do NOT try to answer ad-hoc — the audit needs to actually read files and run commands.
---

# Camoufox Audit Skill

You are auditing a Camoufox multi-account anti-detect browser system. The project root is the current working directory.

Run all checks systematically and produce a structured report. Be concrete — show actual values, not generic advice.

---

## Phase 1 — Read account configs

List all accounts and read their `.env` files:

```bash
ls accounts/
cat accounts/*/.env 2>/dev/null
```

For each account extract: `ACCOUNT`, `PROXY`, `CAM_OS`, `CAM_SEED`, `CAM_SCREEN`, `TZ`, `PORT`.

Build a table:

| Account | Proxy host | CAM_OS | CAM_SEED | CAM_SCREEN | TZ | PORT |
|---------|-----------|--------|----------|------------|-----|------|
| ...     | ...       | ...    | ...      | ...        | ... | ...  |

---

## Phase 2 — Network isolation audit (per running container)

For each running account, execute:

```bash
make check-leaks ACCOUNT=<name>
```

from the project directory. This runs `scripts/check-leaks.sh` inside the container and checks:
- redsocks running
- iptables REDSOCKS chain + DNS block + IPv6 block
- External IP vs proxy host IP
- Direct bypass test (iptables intercepts even `--noproxy` curl)
- ip-api.com geo info + timezone match
- proxycheck.io proxy/VPN flag

Report each check's pass/fail clearly.

**If a container is stopped**, note it and remind: start with `make up ACCOUNT=<name>` then re-run.

---

## Phase 3 — Kill switch analysis (static, no container needed)

Read `scripts/setup-proxy.sh` and answer:

1. **What happens if PROXY env is empty?** → script exits 0, no iptables rules set → real IP exposed. Flag accounts with empty PROXY.
2. **What happens if the proxy server goes down mid-session?** → redsocks fails to connect → TCP connections hang/fail → iptables DROP (no fallback to direct). This IS a kill switch. Confirm.
3. **IPv6?** → `ip6tables -A OUTPUT -j DROP` if ip6tables available. Check if ip6tables is in the Docker image (it is — `iptables` package includes it).
4. **UDP DNS?** → `iptables -A OUTPUT -p udp --dport 53 -j DROP` + TCP 53. DNS resolves via proxy. Confirm.

---

## Phase 4 — Fingerprint isolation audit

Read `scripts/browser.py` and `scripts/new-account.sh`, then analyze:

### 4a. Cross-account linkability risks

Check the accounts table from Phase 1 for:

| Risk | How to check | Severity |
|------|-------------|----------|
| Duplicate CAM_SEED | Are any seeds identical? | CRITICAL — same canvas/audio/font fingerprint |
| Duplicate CAM_OS | Multiple accounts with same OS? | MEDIUM — correlated UA/platform |
| Duplicate CAM_SCREEN | `1280x720` for all? | LOW-MEDIUM — same viewport |
| Same PROXY host | Multiple accounts → same proxy IP | HIGH — IP-level linkage |
| Same PORT | Impossible (conflict), but verify | - |

For CAM_SEED: each account gets `od -An -N4 -tu4 /dev/urandom` on creation → should be unique. Verify no duplicates.

### 4b. What CAM_SEED actually randomizes

From `browser.py`, CAM_SEED seeds:
- `canvas:aaOffset` → ±50 px anti-aliasing noise (canvas fingerprint differs per account)
- `fonts:spacing_seed` → font measurement noise (font fingerprint differs)
- `AudioContext:sampleRate` → one of 44100/55125/66150/77175 Hz (audio fingerprint differs)

**What is NOT randomized per account:**
- `CAM_SCREEN` — hardcoded `1280x720` in `.env` template. All accounts same viewport. Note this.
- WebGL renderer string — Camoufox disables WebGL entirely (no leakage, but absence is itself a signal)
- User-agent — randomized by Camoufox per `CAM_OS` type, not per-seed. Accounts with same `CAM_OS` may share UA family (different minor version is fine).

### 4c. Is fingerprint linked to real machine?

Camoufox runs inside Docker. The browser has no access to:
- Host hardware (no real GPU → WebGL disabled)
- Host MAC address (Docker NAT)
- Host screen resolution (Xvfb virtual display)
- Host fonts (image ships its own Windows fonts)
- Host timezone (container TZ env)

Linkage to real machine is NOT possible via browser APIs if the setup is correct. Confirm by checking:
- `geoip=True` in browser.py → timezone/locale derived from proxy IP, not host
- `user_data_dir="/home/user/.mozilla"` → mounted from `accounts/<name>/profile/` → isolated per account
- No shared volumes between accounts in docker-compose

---

## Phase 5 — Bot detection risk assessment

Analyze each risk factor specific to this setup:

| Factor | Status | Risk level |
|--------|--------|-----------|
| Canvas fingerprint | Randomized via CAM_SEED canvas:aaOffset | Low |
| Audio fingerprint | Randomized via CAM_SEED sampleRate | Low |
| Font fingerprint | Randomized via CAM_SEED fonts:spacing_seed + Windows fonts installed | Low |
| WebGL | Disabled by Camoufox | Low (no leak), but absence detectable |
| WebRTC | Disabled by Camoufox patches | Low |
| User-Agent | Realistic per CAM_OS (Windows/macOS/Linux) | Low |
| Timezone | geoip=True aligns to proxy IP | Low |
| Language/locale | geoip=True | Low |
| Mouse/keyboard | humanize=True | Low |
| Screen resolution | 1280x720 for all accounts | Medium — same for all |
| Navigator.platform | Set by Camoufox per CAM_OS | Low |
| Virtual display (Xvfb) | No GPU, software renderer | Medium — WebGL disabled hides this |
| Proxy IP reputation | Depends on proxy provider | Variable |
| TLS fingerprint (JA3) | Firefox TLS stack (not Chrome) | Low — realistic |
| HTTP/2 fingerprint | Firefox native | Low |
| Cookie isolation | Separate profile dirs | Low |
| localStorage isolation | Separate profile dirs | Low |

**Key findings to highlight:**
- The biggest risk is **proxy IP quality** — datacenter IPs score high on fraud detection. Check proxycheck.io risk score from Phase 2.
- **Screen resolution** `1280x720` is the same across all accounts — not a bot signal by itself, but could be a weak correlation signal between accounts.
- WebGL disabled is unusual but Camoufox handles this in a way that doesn't trigger common bot detectors.

---

## Phase 6 — Browser-side manual checklist

Tell the user to open these URLs in each container's browser and what to look for:

```
https://ipleak.net          → IP, DNS, WebRTC all should show proxy IP (no local IP)
https://browserleaks.com/webrtc  → No IP leak, WebRTC should be disabled
https://browserleaks.com/canvas  → Canvas hash (should differ between accounts)
https://browserleaks.com/fonts   → Font list (should look like Windows system fonts)
https://browserleaks.com/javascript → navigator.* fields match CAM_OS
https://coveryourtracks.eff.org  → "Strong protection" or unique fingerprint acceptable
https://bot.sannysoft.com        → No bot signals should be detected
https://fingerprintjs.com/demo   → Check fingerprint ID changes between sessions/accounts
```

The noVNC URL is `http://localhost:<PORT>/vnc.html`. Run `make status` to get active URLs.

---

## Report format

Structure your final output as:

```
=== CAMOUFOX PRIVACY AUDIT ===
Date: <today>

ACCOUNTS OVERVIEW
<table>

NETWORK AUDIT
[per account: PASS/FAIL for each check]

KILL SWITCH
[static analysis result]

FINGERPRINT ISOLATION
[table of CAM_SEED uniqueness, CAM_OS distribution, etc.]
[list any duplicates or concerns]

BOT DETECTION RISK
[table + narrative for the most important factors]

RECOMMENDATIONS
[numbered list of concrete actions to take, if any]

BROWSER-SIDE CHECKLIST
[URLs with instructions]

OVERALL: GREEN / YELLOW / RED
[one-line verdict]
```

Use GREEN if no issues found, YELLOW if minor concerns (e.g. same screen resolution), RED if actual leaks or critical misconfigurations.