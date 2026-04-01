"""
Shared fingerprint configuration used by browser.py and check-fingerprint.py.
Keep this file in sync with both scripts — it is the single source of truth
for seed derivation logic and anti-detection Firefox prefs.
"""
import hashlib
import os

from browserforge.fingerprints import Screen


def derive_seed(base: int, salt: str) -> int:
    h = hashlib.md5(f"{base}:{salt}".encode()).digest()
    return int.from_bytes(h[:4], "big") or 1


def build_fp_config(cam_seed: int) -> dict:
    """Derive stable per-account Camoufox config from CAM_SEED."""
    if not cam_seed:
        return {}
    return {
        "canvas:aaOffset":         (derive_seed(cam_seed, "canvas") % 11) - 5,  # -5..5
        "fonts:spacing_seed":      derive_seed(cam_seed, "fonts"),
        "AudioContext:sampleRate": [44100, 48000][derive_seed(cam_seed, "audio") % 2],
    }


# Anti-detection Firefox prefs shared by both the persistent session and the
# temporary fingerprint-check instance. Session/cookie prefs are NOT included
# here because they are only meaningful for persistent_context=True.
ANTIDETECT_PREFS: dict = {
    # Battery API: Linux containers return {charging:true, dischargingTime:Infinity}
    # — a well-known VM/container fingerprint. Disable entirely.
    "dom.battery.enabled": False,
    # WebRTC: defense-in-depth on top of Camoufox's built-in patch.
    # A leak of the Docker-internal IP (172.x.x.x) via ICE candidates would
    # immediately reveal the container environment.
    "media.peerconnection.enabled": False,
    "media.peerconnection.ice.no_host": True,
    # SOCKS5 DNS: send DNS queries through the SOCKS proxy, not the local
    # resolver. Required when iptables blocks port 53 (which it does).
    "network.proxy.socks_remote_dns": True,
    # Hardware APIs: containers return empty/error responses that differ from
    # real hardware. Disabling removes the distinguishing signal.
    "device.sensors.enabled": False,
    "dom.vr.enabled": False,
    "dom.gamepad.enabled": False,
}


def build_screen_constraint() -> Screen:
    """Read CAM_SCREEN env and return a browserforge Screen constraint."""
    parts = os.getenv("CAM_SCREEN", "1600x980").split("x")
    return Screen(max_width=int(parts[0]), max_height=int(parts[1]))


def screen_dimensions() -> tuple[int, int]:
    """Return (width, height) from CAM_SCREEN env."""
    parts = os.getenv("CAM_SCREEN", "1600x980").split("x")
    return int(parts[0]), int(parts[1])
