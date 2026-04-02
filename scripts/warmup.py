#!/usr/bin/env python3
"""
Browser profile warm-up script.

Visits a curated sequence of sites to build up cookies, cache, and browsing
history — making the profile look like a real user.

Custom sites can be added without touching this file: create
scripts/warmup_custom.py (gitignored) and define WARMUP_PLAN_EXTRA there.
It will be appended automatically to the base plan.

Run via:  make warmup ACCOUNT=<name>
"""
import os
import random
import sys
import time
from urllib.parse import urlparse

from camoufox.sync_api import Camoufox
from fp_config import ANTIDETECT_PREFS, build_fp_config, build_screen_constraint

# ── Sites visited during warm-up ─────────────────────────────────────────────
# Connect via VNC to monitor and manually solve any CAPTCHAs that appear.
#
# Strategy:
#  • Wikipedia / news / Stack Overflow — no bot protection, build general history
#  • Avoid Google/YouTube in the automated list — they trigger reCAPTCHA on
#    fresh profiles; do those manually via VNC after this script finishes
#
# Add site-specific entries in scripts/warmup_custom.py (gitignored) via
# WARMUP_PLAN_EXTRA — same tuple format: (label, url, min_s, max_s)
WARMUP_PLAN = [
    # label,            url,                                        min_s, max_s
    ("Wikipedia",       "https://en.wikipedia.org/wiki/Freelance", 20, 35),
    ("Stack Overflow",  "https://stackoverflow.com",               20, 30),
    ("BBC News",        "https://www.bbc.com/news",                20, 30),
]

# ── Custom extension (gitignored) ─────────────────────────────────────────────
try:
    from warmup_custom import WARMUP_PLAN_EXTRA  # type: ignore[import]
    WARMUP_PLAN = WARMUP_PLAN + WARMUP_PLAN_EXTRA
    print(f"[warmup] Loaded {len(WARMUP_PLAN_EXTRA)} custom entries from warmup_custom.py")
except ImportError:
    pass

# ── Proxy config (same logic as browser.py) ──────────────────────────────────
proxy_url = os.getenv("PROXY")
proxy = None
if proxy_url:
    p = urlparse(proxy_url)
    proxy = {"server": f"{p.scheme}://{p.hostname}:{p.port}"}
    if p.username:
        proxy["username"] = p.username
    if p.password:
        proxy["password"] = p.password

os_type  = os.getenv("CAM_OS", "windows")
fp_conf  = build_fp_config(int(os.getenv("CAM_SEED", "0")))
screen   = build_screen_constraint()

total_min = sum(lo for _, _, lo, _ in WARMUP_PLAN)
total_max = sum(hi for _, _, _, hi in WARMUP_PLAN)
print(f"[warmup] Profile warm-up starting ({len(WARMUP_PLAN)} sites, "
      f"~{total_min//60}–{total_max//60} min)")
print(f"[warmup] os={os_type}  proxy={'set' if proxy else 'none'}")

# ── Session prefs: same as browser.py (persist cookies/history) ──────────────
_session_prefs = {
    "browser.startup.page":                    0,      # blank on start
    "privacy.sanitize.sanitizeOnShutdown":     False,
    "privacy.clearOnShutdown.cookies":         False,
    "privacy.clearOnShutdown.sessions":        False,
    "privacy.clearOnShutdown.offlineApps":     False,
    "privacy.clearOnShutdown.cache":           False,
    "privacy.clearOnShutdown.formdata":        False,
    "privacy.clearOnShutdown.history":         False,
    "network.cookie.lifetimePolicy":           0,
}

with Camoufox(
    headless=False,
    os=os_type,
    geoip=True,
    proxy=proxy,
    humanize=True,
    persistent_context=True,
    user_data_dir="/home/user/.mozilla",
    firefox_user_prefs={**ANTIDETECT_PREFS, **_session_prefs},
    config=fp_conf,
    screen=screen,
    enable_cache=True,
) as browser:
    page = browser.new_page()

    for i, (label, url, lo, hi) in enumerate(WARMUP_PLAN, 1):
        dwell = random.randint(lo, hi)
        print(f"[warmup] [{i}/{len(WARMUP_PLAN)}] {label}  (dwell {dwell}s)")
        print(f"[warmup]          {url}")
        try:
            page.goto(url, timeout=45000, wait_until="domcontentloaded")
            # Simulate reading: scroll down gradually then back up
            page.evaluate("""() => {
                const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
                if (maxScroll <= 0) return;
                const target = Math.random() * Math.min(maxScroll, 2000) + 200;
                window.scrollTo({top: target, behavior: 'smooth'});
            }""")
            time.sleep(dwell * 0.6)
            # Scroll back up partway (natural reading behaviour)
            page.evaluate("""() => {
                const cur = window.scrollY;
                if (cur > 300) {
                    window.scrollTo({top: cur * 0.3, behavior: 'smooth'});
                }
            }""")
            time.sleep(dwell * 0.4)
        except Exception as e:
            print(f"[warmup]   WARNING: {e.__class__.__name__}: {e}")
            time.sleep(5)

print("[warmup] Done. Profile saved — cookies and history are now primed.")
print("[warmup] Run 'make up ACCOUNT=<name>' to start the normal browser session.")
