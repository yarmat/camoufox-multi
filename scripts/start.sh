#!/bin/bash
set -e

# ── Network-level transparent proxy (runs as root) ───────────────────────────
bash /scripts/setup-proxy.sh

# ── Virtual display ──────────────────────────────────────────────────────────
# Run Xvfb at exactly CAM_SCREEN so window.screen.availWidth == window.screen.width.
# The +200px margin was previously used for window decorations, but it caused
# availWidth to exceed screen.width — a physically impossible value detectable by
# bot-detection scripts. The browser window is now sized 80px shorter than the
# screen to leave room for the Firefox titlebar (see browser.py _window_size).
_CAM_SCREEN="${CAM_SCREEN:-1600x980}"
_XVFB_W=${_CAM_SCREEN%%x*}
_XVFB_H=${_CAM_SCREEN##*x}
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 "${_XVFB_W}x${_XVFB_H}x24" &
export DISPLAY=:99
sleep 1

# ── VNC server ───────────────────────────────────────────────────────────────
if [ -n "$VNC_PW" ]; then
    x11vnc -display :99 -passwd "$VNC_PW" -listen 0.0.0.0 -xkb -forever &
else
    x11vnc -display :99 -nopw -listen 0.0.0.0 -xkb -forever &
fi
sleep 1

# ── noVNC websocket proxy ────────────────────────────────────────────────────
websockify --web=/usr/share/novnc 6901 localhost:5900 &

# ── Drop root, launch browser as unprivileged user ───────────────────────────
# BROWSER_SCRIPT can be overridden (e.g. /scripts/warmup.py) via docker run -e
exec gosu user python "${BROWSER_SCRIPT:-/scripts/browser.py}"