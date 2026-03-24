#!/bin/bash
set -e

# ── Network-level transparent proxy (runs as root) ───────────────────────────
bash /scripts/setup-proxy.sh

# ── Virtual display ──────────────────────────────────────────────────────────
# Add margin so noVNC fits the full Firefox window (Camoufox screen size is approximate)
_CAM_SCREEN="${CAM_SCREEN:-1600x980}"
_XVFB_W=$(( ${_CAM_SCREEN%%x*} + 200 ))
_XVFB_H=$(( ${_CAM_SCREEN##*x} + 200 ))
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
exec gosu user python /scripts/browser.py