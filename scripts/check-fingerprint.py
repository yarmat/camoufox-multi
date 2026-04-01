#!/usr/bin/env python3
"""
Browser fingerprint consistency checker.
Launched inside the container by check-leaks.sh as an unprivileged user.
Starts a temporary (non-persistent) Camoufox instance, runs JS probes,
then exits. Does NOT touch the persistent profile used by browser.py.
"""
import os
import re
import sys

from camoufox.sync_api import Camoufox
from fp_config import ANTIDETECT_PREFS, build_fp_config, build_screen_constraint, screen_dimensions

# ── colour helpers ────────────────────────────────────────────────────────────
GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
BOLD   = "\033[1m"
NC     = "\033[0m"

passed = 0
failed = 0

def ok(label, detail=""):
    global passed
    passed += 1
    print(f"  {GREEN}✓{NC} {label}" + (f": {detail}" if detail else ""))

def fail(label, detail=""):
    global failed
    failed += 1
    print(f"  {RED}✗{NC} {label}" + (f": {detail}" if detail else ""))

def info(label, detail=""):
    print(f"  {CYAN}→{NC} {label}" + (f": {detail}" if detail else ""))

def check(label, condition, ok_detail="", fail_detail=""):
    if condition:
        ok(label, ok_detail)
    else:
        fail(label, fail_detail)


# ── read the same env-vars as browser.py ─────────────────────────────────────
os_type      = os.getenv("CAM_OS", "windows")
container_tz = os.getenv("TZ", "")
fp_config    = build_fp_config(int(os.getenv("CAM_SEED", "0")))
_screen_w, _screen_h = screen_dimensions()

print(f"\n{BOLD}=== Browser Fingerprint Check "
      f"(os={os_type}, screen={_screen_w}x{_screen_h}) ==={NC}\n")

try:
    with Camoufox(
        headless=False,
        os=os_type,
        geoip=True,
        config=fp_config,
        screen=build_screen_constraint(),
        enable_cache=False,
        # Temporary profile — does NOT conflict with the running browser.py session
        persistent_context=False,
        firefox_user_prefs=ANTIDETECT_PREFS,
    ) as browser:
        page = browser.new_page()
        page.goto("about:blank", timeout=20000)

        # ── [A] Screen geometry ───────────────────────────────────────────────
        print(f"{BOLD}[A] Screen geometry{NC}")
        d = page.evaluate("""() => ({
            sw:  screen.width,       sh:  screen.height,
            saw: screen.availWidth,  sah: screen.availHeight,
            cd:  screen.colorDepth,  dpr: devicePixelRatio,
            ow:  outerWidth,         oh:  outerHeight,
            iw:  innerWidth,         ih:  innerHeight,
        })""")
        info(f"screen      {d['sw']}x{d['sh']}  "
             f"avail {d['saw']}x{d['sah']}  "
             f"colorDepth {d['cd']}  DPR {d['dpr']}")
        info(f"outerWindow {d['ow']}x{d['oh']}  "
             f"innerViewport {d['iw']}x{d['ih']}")
        check("screen.width ≥ outerWidth ≥ innerWidth",
              d['sw'] >= d['ow'] >= d['iw'],
              f"{d['sw']} ≥ {d['ow']} ≥ {d['iw']}",
              f"IMPOSSIBLE GEOMETRY: screen={d['sw']} outer={d['ow']} inner={d['iw']}")
        check("availWidth ≤ screen.width  (no Xvfb size leak)",
              d['saw'] <= d['sw'],
              f"{d['saw']} ≤ {d['sw']}",
              f"XVFB LEAK: availWidth={d['saw']} > screen.width={d['sw']}")
        # 24 = standard 8bpc (Windows/Linux), 30 = 10bpc HDR/P3 (macOS Retina), 32 = 8bpc+alpha
        check("colorDepth is realistic (24 / 30 / 32)",
              d['cd'] in (24, 30, 32), str(d['cd']), f"unusual: {d['cd']}")
        check("devicePixelRatio ≥ 1",
              d['dpr'] >= 1.0, str(d['dpr']), str(d['dpr']))

        # ── [B] navigator properties ──────────────────────────────────────────
        print(f"\n{BOLD}[B] Navigator{NC}")
        nav = page.evaluate("""() => ({
            webdriver:           navigator.webdriver,
            platform:            navigator.platform,
            language:            navigator.language,
            languages:           Array.from(navigator.languages || []).join(', '),
            hardwareConcurrency: navigator.hardwareConcurrency,
            deviceMemory:        navigator.deviceMemory,
            userAgent:           navigator.userAgent,
            oscpu:               navigator.oscpu,
            cookieEnabled:       navigator.cookieEnabled,
            doNotTrack:          navigator.doNotTrack,
            plugins:             navigator.plugins.length,
            mimeTypes:           navigator.mimeTypes.length,
            maxTouchPoints:      navigator.maxTouchPoints,
        })""")
        info(f"userAgent           {nav['userAgent']}")
        info(f"platform            {nav['platform']}  "
             f"oscpu {nav['oscpu']}")
        info(f"language            {nav['language']}  "
             f"languages [{nav['languages']}]")
        info(f"hardwareConcurrency {nav['hardwareConcurrency']}  "
             f"deviceMemory {nav['deviceMemory']}")
        info(f"plugins {nav['plugins']}  "
             f"mimeTypes {nav['mimeTypes']}  "
             f"maxTouchPoints {nav['maxTouchPoints']}  "
             f"cookieEnabled {nav['cookieEnabled']}")
        check("navigator.webdriver hidden",
              not nav['webdriver'], "undefined / false", "EXPOSED — bot signal!")
        check("platform is not Linux x86_64",
              "Linux" not in str(nav['platform']),
              nav['platform'],
              f"LINUX LEAK: {nav['platform']}")
        check("language not empty",
              bool(nav['language']), nav['language'], "empty — geoip/locale broken?")
        check("maxTouchPoints is 0 (desktop, no touch screen)",
              nav['maxTouchPoints'] == 0,
              "0", f"unexpected: {nav['maxTouchPoints']}")

        # ── [C] Automation artifacts ──────────────────────────────────────────
        print(f"\n{BOLD}[C] Automation / stealth artifacts{NC}")
        artifacts = page.evaluate("""() => {
            const f = [];
            if (navigator.webdriver)                                f.push('navigator.webdriver=true');
            if (typeof __playwright        !== 'undefined')         f.push('__playwright');
            if (typeof __pwInitScripts     !== 'undefined')         f.push('__pwInitScripts');
            if (typeof __PW_inspect        !== 'undefined')         f.push('__PW_inspect');
            if (window.callPhantom)                                  f.push('callPhantom');
            if (window._phantom)                                     f.push('_phantom');
            if (window.__nightmare)                                  f.push('__nightmare');
            if (window.domAutomation)                               f.push('domAutomation');
            if (window.domAutomationController)                     f.push('domAutomationController');
            // Check for proxy traps — JS-overridden getters are detectable via toString.
            // Camoufox patches at the Firefox binary level, so this should throw (native).
            try {
                const desc = Object.getOwnPropertyDescriptor(navigator, 'webdriver');
                if (desc && typeof desc.get === 'function') {
                    const src = Function.prototype.toString.call(desc.get);
                    if (!src.includes('[native code]')) f.push('webdriver-getter-patched-JS');
                }
            } catch(_) { /* native-level patch — expected */ }
            return f.length === 0 ? 'clean' : f.join(', ');
        }""")
        check("no automation globals found", artifacts == "clean",
              "clean", f"FOUND: {artifacts}")

        # ── [D] Battery API ───────────────────────────────────────────────────
        print(f"\n{BOLD}[D] Battery API{NC}")
        battery_exposed = page.evaluate("() => 'getBattery' in navigator")
        check("navigator.getBattery hidden",
              not battery_exposed,
              "disabled (dom.battery.enabled=false)",
              "EXPOSED — containers always return {charging:true,dischargingTime:Infinity}")

        # ── [E] WebRTC ────────────────────────────────────────────────────────
        print(f"\n{BOLD}[E] WebRTC{NC}")
        rtc = page.evaluate("""() => ({
            RTCPeerConnection:    typeof RTCPeerConnection    !== 'undefined',
            mozRTCPeerConnection: typeof mozRTCPeerConnection !== 'undefined',
            mediaDevices:         typeof navigator.mediaDevices !== 'undefined',
            getUserMedia:         typeof navigator.getUserMedia !== 'undefined',
        })""")
        info(f"RTCPeerConnection {rtc['RTCPeerConnection']}  "
             f"mozRTC {rtc['mozRTCPeerConnection']}  "
             f"mediaDevices {rtc['mediaDevices']}  "
             f"getUserMedia {rtc['getUserMedia']}")
        check("RTCPeerConnection disabled",
              not rtc['RTCPeerConnection'],
              "hidden",
              "EXPOSED — ICE candidates could leak Docker-internal IP (172.x.x.x)!")

        # ── [F] Timezone & locale ─────────────────────────────────────────────
        print(f"\n{BOLD}[F] Timezone / locale{NC}")
        tz = page.evaluate("""() => ({
            tz:     Intl.DateTimeFormat().resolvedOptions().timeZone,
            locale: Intl.DateTimeFormat().resolvedOptions().locale,
            offset: new Date().getTimezoneOffset(),
        })""")
        utc_h = -tz['offset'] // 60
        info(f"timezone {tz['tz']}  locale {tz['locale']}  UTC offset {utc_h:+}h")
        check("timezone not empty", bool(tz['tz']),
              tz['tz'], "empty — geoip=True failed?")
        # Only compare when TZ is not a raw offset like "UTC+2"
        if container_tz and not container_tz.startswith("UTC"):
            check("browser TZ matches container TZ",
                  tz['tz'] == container_tz,
                  f"{tz['tz']} == {container_tz}",
                  f"MISMATCH: browser={tz['tz']} != container TZ={container_tz}")

        # ── [G] WebGL renderer ────────────────────────────────────────────────
        print(f"\n{BOLD}[G] WebGL renderer (software renderer leak){NC}")
        wgl = page.evaluate("""() => {
            try {
                const c  = document.createElement('canvas');
                const gl = c.getContext('webgl') || c.getContext('experimental-webgl');
                if (!gl) return {renderer: 'unavailable', vendor: 'unavailable'};
                const ext = gl.getExtension('WEBGL_debug_renderer_info');
                if (!ext) return {renderer: 'no WEBGL_debug_renderer_info', vendor: 'hidden'};
                return {
                    renderer: gl.getParameter(ext.UNMASKED_RENDERER_WEBGL),
                    vendor:   gl.getParameter(ext.UNMASKED_VENDOR_WEBGL),
                };
            } catch(e) { return {renderer: 'error: '+e, vendor: 'error'}; }
        }""")
        info(f"renderer  {wgl['renderer']}")
        info(f"vendor    {wgl['vendor']}")
        renderer_lc = str(wgl['renderer']).lower()
        vendor_lc   = str(wgl['vendor']).lower()
        check("renderer is not LLVMpipe/softpipe",
              "llvmpipe" not in renderer_lc and "softpipe" not in renderer_lc
              and "software" not in renderer_lc,
              "spoofed", f"SOFTWARE RENDERER LEAK: {wgl['renderer']}")
        check("vendor is not Mesa/VMware",
              "mesa" not in vendor_lc and "vmware" not in vendor_lc,
              "spoofed", f"MESA/VM LEAK: {wgl['vendor']}")

        # ── [H] Canvas fingerprint stability ─────────────────────────────────
        print(f"\n{BOLD}[H] Canvas fingerprint (seed stability){NC}")
        canvas_hash = page.evaluate("""() => {
            const c   = document.createElement('canvas');
            c.width   = 280; c.height = 60;
            const ctx = c.getContext('2d');
            ctx.textBaseline = 'alphabetic';
            ctx.fillStyle    = '#f60';
            ctx.fillRect(125, 1, 62, 20);
            ctx.fillStyle = '#069';
            ctx.font      = '11pt no-real-font-xyz';
            ctx.fillText('Cwm fjordbank glyphs vext quiz \U0001F600', 2, 15);
            ctx.fillStyle = 'rgba(102,204,0,0.7)';
            ctx.font      = '18pt Arial';
            ctx.fillText('Cwm fjordbank glyphs vext quiz', 4, 45);
            const data = c.toDataURL();
            let h = 0;
            for (let i = 0; i < data.length; i++) {
                h = (Math.imul(31, h) + data.charCodeAt(i)) | 0;
            }
            return (h >>> 0).toString(16).padStart(8, '0');
        }""")
        info(f"hash {canvas_hash}  "
             "(must be identical across container restarts for same CAM_SEED)")
        check("canvas hash is not 00000000",
              canvas_hash != "00000000", canvas_hash, "zero hash — canvas blocked?")

        # ── [I] Hardware & exotic APIs ────────────────────────────────────────
        print(f"\n{BOLD}[I] Hardware / exotic APIs{NC}")
        hw = page.evaluate("""() => ({
            battery:    'getBattery'          in navigator,
            gamepad:    typeof navigator.getGamepads === 'function',
            vr:         typeof navigator.getVRDisplays === 'function',
            sensor:     typeof Sensor         !== 'undefined',
            bluetooth:  'bluetooth'           in navigator,
            usb:        'usb'                 in navigator,
            serial:     'serial'              in navigator,
            hid:        'hid'                 in navigator,
            nfc:        'nfc'                 in navigator,
            perfMemory: typeof performance !== 'undefined' && 'memory' in performance,
        })""")
        for api, exposed in hw.items():
            # battery/gamepad/vr/sensor should be hidden after our prefs
            should_be_hidden = api in ("battery", "gamepad", "vr", "sensor")
            if should_be_hidden:
                check(f"{api} API hidden", not exposed,
                      "hidden", "exposed — bot signal!")
            else:
                status = "exposed" if exposed else "hidden"
                info(f"{api:12} {status}")

        # perfMemory is Chrome-only; should always be absent in Firefox
        check("performance.memory absent (Firefox, not Chrome)",
              not hw['perfMemory'], "absent", "PRESENT — wrong UA?")

        # ── regex for private/container IP ranges (used in J, N, O) ─────────
        _priv = re.compile(
            r'\b(10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+'
            r'|192\.168\.\d+\.\d+|127\.\d+\.\d+\.\d+|169\.254\.\d+\.\d+)\b'
        )

        # ── [J] Active WebRTC ICE candidate probe ────────────────────────────
        print(f"\n{BOLD}[J] Active WebRTC ICE probe (gather ICE candidates){NC}")
        ice = page.evaluate("""() => new Promise(resolve => {
            if (typeof RTCPeerConnection === 'undefined') {
                resolve({api: false, candidates: []});
                return;
            }
            const cands = [];
            const pc = new RTCPeerConnection({
                iceServers: [{urls: 'stun:stun.l.google.com:19302'}]
            });
            const t = setTimeout(() => {
                try { pc.close(); } catch(_) {}
                resolve({api: true, candidates: cands});
            }, 5000);
            pc.onicecandidate = e => {
                if (e.candidate) {
                    cands.push(e.candidate.candidate);
                } else {
                    clearTimeout(t);
                    try { pc.close(); } catch(_) {}
                    resolve({api: true, candidates: cands});
                }
            };
            pc.createDataChannel('test');
            pc.createOffer()
                .then(o => pc.setLocalDescription(o))
                .catch(() => { clearTimeout(t); resolve({api: true, candidates: []}); });
        })""")
        if not ice['api']:
            ok("RTCPeerConnection API absent — ICE gathering impossible", "API disabled")
        else:
            leaking = [c for c in ice['candidates'] if _priv.search(c)]
            for c in ice['candidates']:
                info(f"  ICE: {c[:90]}")
            if not ice['candidates']:
                info("no ICE candidates gathered (expected if STUN unreachable via proxy)")
            check("No private/container IP in ICE candidates",
                  not leaking,
                  f"{len(ice['candidates'])} candidates — no private IPs",
                  f"PRIVATE IP LEAK: {leaking[0][:80] if leaking else ''}")

        # ── [K] In-browser fetch: external IP (routes through proxy) ─────────
        print(f"\n{BOLD}[K] External IP via browser fetch (proxy routing){NC}")
        ip_res = page.evaluate("""() =>
            fetch('https://ipinfo.io/json', {cache: 'no-store'})
              .then(r => r.json())
              .catch(e => ({_error: String(e)}))
        """)
        if '_error' in ip_res:
            fail("ipinfo.io fetch failed", ip_res['_error'])
        else:
            info(f"IP:       {ip_res.get('ip', '?')}")
            info(f"Org/ASN:  {ip_res.get('org', '?')}")
            info(f"Location: {ip_res.get('city', '?')}, "
                 f"{ip_res.get('region', '?')}, {ip_res.get('country', '?')}")
            info(f"Timezone: {ip_res.get('timezone', '?')}")
            ok("Browser fetch reached ipinfo.io (proxy routing works)", ip_res.get('ip', ''))

        # ── [L] Cloudflare /cdn-cgi/trace ─────────────────────────────────────
        print(f"\n{BOLD}[L] Cloudflare trace{NC}")
        cf_raw = page.evaluate("""() =>
            fetch('https://www.cloudflare.com/cdn-cgi/trace', {cache: 'no-store'})
              .then(r => r.text())
              .catch(e => '_error=' + e)
        """)
        if cf_raw.startswith('_error='):
            fail("Cloudflare trace fetch", cf_raw[7:80])
        else:
            cf = {k: v for line in cf_raw.strip().splitlines()
                  if '=' in line for k, v in [line.split('=', 1)]}
            info(f"ip={cf.get('ip','?')}  loc={cf.get('loc','?')}  colo={cf.get('colo','?')}")
            info(f"uag (UA as seen by CF): {cf.get('uag','?')[:90]}")
            info(f"h={cf.get('h','?')}  tls={cf.get('tls','?')}")
            ok("Cloudflare trace succeeded", f"cf-ip={cf.get('ip','?')}")

        # ── [M] Windows font presence (multi-fallback canvas measurement) ───────
        # Compare each font against serif, sans-serif AND monospace fallbacks.
        # A font is considered present if its metrics differ from ANY fallback by > 0.5px.
        # This correctly handles monospace fonts like Courier New which look similar
        # to the 'monospace' fallback but differ clearly from 'serif'/'sans-serif'.
        print(f"\n{BOLD}[M] Windows font presence (canvas measurement){NC}")
        fonts_found = page.evaluate("""() => {
            const PROBE = 'mmmmmmmmmmlliiiiWWWW';
            const FALLBACKS = ['serif', 'sans-serif', 'monospace'];
            const getBases = () => {
                const ctx = document.createElement('canvas').getContext('2d');
                return FALLBACKS.map(f => {
                    ctx.font = `16px ${f}`;
                    return ctx.measureText(PROBE).width;
                });
            };
            const bases = getBases();
            const test = font => {
                const ctx = document.createElement('canvas').getContext('2d');
                return FALLBACKS.some((f, i) => {
                    ctx.font = `16px '${font}', ${f}`;
                    return Math.abs(ctx.measureText(PROBE).width - bases[i]) > 0.5;
                });
            };
            const fonts = [
                'Arial', 'Times New Roman', 'Verdana', 'Georgia', 'Courier New',
                'Calibri', 'Cambria', 'Consolas', 'Segoe UI', 'Tahoma',
                'Trebuchet MS', 'Impact', 'Comic Sans MS', 'Arial Black',
                'Palatino Linotype', 'Book Antiqua'
            ];
            return fonts.reduce((acc, f) => { acc[f] = test(f); return acc; }, {});
        }""")
        f_present = [f for f, found in fonts_found.items() if found]
        f_missing = [f for f, found in fonts_found.items() if not found]
        info(f"Detected  ({len(f_present)}): {', '.join(f_present)}")
        if f_missing:
            info(f"Not found ({len(f_missing)}): {', '.join(f_missing)}")
        _core_fonts = {'Arial', 'Times New Roman', 'Verdana', 'Georgia',
                       'Courier New', 'Impact', 'Comic Sans MS', 'Trebuchet MS'}
        key_missing = _core_fonts - set(f_present)
        check("MS core fonts present (ttf-mscorefonts-installer)",
              not key_missing,
              f"{len(f_present)}/16 fonts found",
              f"MISSING: {key_missing}")

        # ── [N] browserleaks.com/webrtc ───────────────────────────────────────
        print(f"\n{BOLD}[N] browserleaks.com — WebRTC leak test{NC}")
        try:
            page.goto("https://browserleaks.com/webrtc", timeout=30000)
            page.wait_for_load_state("load", timeout=20000)
            page.wait_for_timeout(2000)
            bl_rtc = page.evaluate("""() => {
                const ipPat = /\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b/;
                const rows  = [...document.querySelectorAll('table tr')]
                    .map(r => r.innerText?.trim() || '')
                    .filter(t => ipPat.test(t));
                const rtcCells = [...document.querySelectorAll(
                    '[class*="rtc"], [id*="rtc"], .ip-address, td'
                )].map(e => e.textContent?.trim()).filter(Boolean);
                return {
                    ipRows:  rows,
                    textLen: document.body?.innerText?.length || 0,
                };
            }""")
            info(f"Page loaded ({bl_rtc['textLen']} chars)")
            for row in bl_rtc['ipRows'][:6]:
                info(f"  row: {row[:90]}")
            private_rows = [r for r in bl_rtc['ipRows'] if _priv.search(r)]
            check("No private IPs on browserleaks.com/webrtc",
                  not private_rows,
                  "clean" if bl_rtc['ipRows'] else "no IPs visible (WebRTC disabled)",
                  f"LEAK: {private_rows[0][:80] if private_rows else ''}")
        except Exception as e:
            info(f"browserleaks.com/webrtc skipped: {e.__class__.__name__}: {str(e)[:60]}")

        # ── [O] ipleak.net ────────────────────────────────────────────────────
        print(f"\n{BOLD}[O] ipleak.net — overall leak check{NC}")
        try:
            page.goto("https://ipleak.net", timeout=30000)
            page.wait_for_load_state("load", timeout=20000)
            page.wait_for_timeout(4000)   # JS-populated results need time
            il = page.evaluate("""() => {
                const ipEl   = document.querySelector('#ip-dns, .ip-dns, [id*="ip"]');
                const rtcEls = [...document.querySelectorAll(
                    '.rtc_ip_address, [class*="rtc_ip"], [class*="webrtc"] li'
                )];
                return {
                    ip:      ipEl?.textContent?.trim() || '',
                    rtcIPs:  rtcEls.map(e => e.textContent?.trim()).filter(Boolean),
                    textLen: document.body?.innerText?.length || 0,
                };
            }""")
            info(f"Page loaded ({il['textLen']} chars)")
            info(f"Detected IP: {il['ip'] or '(not extracted)'}")
            for ip in il['rtcIPs'][:5]:
                info(f"  WebRTC IP shown: {ip}")
            private_rtc = [ip for ip in il['rtcIPs'] if _priv.search(ip)]
            check("No private/container IPs on ipleak.net",
                  not private_rtc,
                  "clean" if not il['rtcIPs'] else f"rtc IPs visible: {il['rtcIPs']}",
                  f"LEAK: {private_rtc}")
        except Exception as e:
            info(f"ipleak.net skipped: {e.__class__.__name__}: {str(e)[:60]}")

except Exception as exc:
    print(f"\n{RED}ERROR: fingerprint check failed: {exc}{NC}", file=sys.stderr)
    sys.exit(2)

# ── summary ───────────────────────────────────────────────────────────────────
print(f"\n{'='*52}")
print(f"{BOLD}Fingerprint check summary: "
      f"{GREEN}{passed} passed{NC}{BOLD}, "
      f"{RED if failed else GREEN}{failed} failed{NC}")
if failed:
    print(f"{YELLOW}⚠ Issues found — review above{NC}\n")
    sys.exit(1)
else:
    print(f"{GREEN}✓ All fingerprint checks passed{NC}\n")
