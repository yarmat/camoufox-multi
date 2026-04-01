from camoufox.sync_api import Camoufox
from urllib.parse import urlparse
from fp_config import ANTIDETECT_PREFS, build_fp_config, build_screen_constraint
import os
import re
import signal
import sys
import time

proxy_url  = os.getenv("PROXY")
os_type    = os.getenv("CAM_OS", "windows")
homepage   = os.getenv("HOMEPAGE", "https://ipleak.net")

fp_config = build_fp_config(int(os.getenv("CAM_SEED", "0")))

proxy = None
if proxy_url:
    p = urlparse(proxy_url)
    proxy = {"server": f"{p.scheme}://{p.hostname}:{p.port}"}
    if p.username:
        proxy["username"] = p.username
    if p.password:
        proxy["password"] = p.password

_proxy_log = re.sub(r'(?<=://)([^@]+)(?=@)', '***', proxy_url) if proxy_url else 'none'
print(f"[browser] Starting Camoufox: os={os_type}, proxy={_proxy_log}, homepage={homepage}")
print(f"[browser] Fingerprint seeds: {fp_config}")

# Let browserforge pick a real screen resolution from its database that fits within
# CAM_SCREEN. The window= parameter is intentionally omitted so Camoufox sizes the
# browser window automatically based on the chosen screen fingerprint — this avoids
# the impossible window.innerWidth > window.screen.width mismatch that occurs when
# a fixed window size is larger than the fingerprinted screen size.
constrains = build_screen_constraint()

def _graceful_exit(signum, frame):
    """Handle SIGTERM/SIGINT so the 'with Camoufox' block exits cleanly,
    flushing Firefox profile (cookies, sessions) to disk before shutdown."""
    print(f"[browser] Signal {signum} received — shutting down gracefully")
    sys.exit(0)

signal.signal(signal.SIGTERM, _graceful_exit)
signal.signal(signal.SIGINT, _graceful_exit)

with Camoufox(
    headless=False,
    os=os_type,
    geoip=True,
    proxy=proxy,
    humanize=True,
    persistent_context=True,
    user_data_dir="/home/user/.mozilla",
    firefox_user_prefs={
        "browser.startup.page": 3,                  # restore previous session on startup
        "privacy.sanitize.sanitizeOnShutdown": False,
        "privacy.clearOnShutdown.cookies": False,
        "privacy.clearOnShutdown.sessions": False,
        "privacy.clearOnShutdown.offlineApps": False,
        "privacy.clearOnShutdown.cache": False,
        "privacy.clearOnShutdown.formdata": False,
        "privacy.clearOnShutdown.history": False,
        "network.cookie.lifetimePolicy": 0,          # keep cookies across restarts
        **ANTIDETECT_PREFS,
    },
    config=fp_config,
    screen=constrains,
    enable_cache=True,
) as browser:
    blank_urls = ("about:blank", "about:newtab", "about:home", "")
    all_pages = browser.pages
    real_pages = [p for p in all_pages if p.url not in blank_urls]
    blank_pages = [p for p in all_pages if p.url in blank_urls]
    if real_pages:
        # Session restored — close leftover blank tabs
        for p in blank_pages:
            p.close()
        print(f"[browser] Restored previous session ({len(real_pages)} tab(s))")
    else:
        # No real session — navigate first blank page to homepage, close the rest
        if blank_pages:
            page = blank_pages[0]
            for p in blank_pages[1:]:
                p.close()
        else:
            page = browser.new_page()
        try:
            page.goto(homepage, timeout=60000)
            print(f"[browser] Page loaded: {homepage}")
        except Exception as e:
            print(f"[browser] WARNING: Could not load homepage ({e.__class__.__name__}), continuing anyway")
    while True:
        time.sleep(60)
