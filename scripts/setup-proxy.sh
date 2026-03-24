#!/bin/bash
# Transparent network-level proxy via redsocks + iptables.
# Runs as root before the browser starts.
# ALL TCP traffic from the container is forced through the proxy.
# UDP DNS is blocked to prevent leaks (browser uses proxy-based DNS).

set -e

PROXY="${PROXY:-}"

if [ -z "$PROXY" ]; then
    echo "[proxy] ERROR: No PROXY configured — refusing to start (real IP would be exposed)"
    exit 1
fi

# ── Parse proxy URL ──────────────────────────────────────────────────────────
# Formats: http://host:port  |  http://user:pass@host:port  |  socks5://...

PROXY_SCHEME=$(echo "$PROXY" | grep -oP '^[a-z0-9+]+(?=://)')
PROXY_REST=$(echo "$PROXY" | sed 's|^[a-z0-9+]*://||')

if echo "$PROXY_REST" | grep -q '@'; then
    PROXY_USERINFO=$(echo "$PROXY_REST" | grep -oP '^[^@]+(?=@)')
    PROXY_HOSTPORT=$(echo "$PROXY_REST" | grep -oP '[^@]+$')
    PROXY_USER=$(echo "$PROXY_USERINFO" | cut -d: -f1)
    PROXY_PASS=$(echo "$PROXY_USERINFO" | cut -d: -f2-)
else
    PROXY_HOSTPORT="$PROXY_REST"
    PROXY_USER=""
    PROXY_PASS=""
fi

PROXY_HOST=$(echo "$PROXY_HOSTPORT" | cut -d: -f1)
PROXY_PORT=$(echo "$PROXY_HOSTPORT" | cut -d: -f2)

# Resolve hostname → IP before iptables locks routing
if ! echo "$PROXY_HOST" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$'; then
    PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{print $1}' | head -1)
    if [ -z "$PROXY_IP" ]; then
        echo "[proxy] ERROR: Cannot resolve proxy host '$PROXY_HOST'"
        exit 1
    fi
    echo "[proxy] Resolved $PROXY_HOST → $PROXY_IP"
else
    PROXY_IP="$PROXY_HOST"
fi

# Map scheme to redsocks type
case "$PROXY_SCHEME" in
    socks5)        REDSOCKS_TYPE="socks5" ;;
    socks4)        REDSOCKS_TYPE="socks4" ;;
    http|https)    REDSOCKS_TYPE="http-connect" ;;
    *)             REDSOCKS_TYPE="http-connect" ;;
esac

echo "[proxy] Setting up transparent proxy: ${REDSOCKS_TYPE} → ${PROXY_IP}:${PROXY_PORT}"

# ── Write redsocks config ────────────────────────────────────────────────────
REDSOCKS_CONF=/tmp/redsocks.conf
cat > "$REDSOCKS_CONF" <<EOF
base {
    log_debug = off;
    log_info  = on;
    log       = "stderr";
    daemon    = off;
    redirector = iptables;
}

redsocks {
    local_ip   = 127.0.0.1;
    local_port = 12345;
    ip         = ${PROXY_IP};
    port       = ${PROXY_PORT};
    type       = ${REDSOCKS_TYPE};
EOF

if [ -n "$PROXY_USER" ]; then
    echo "    login    = \"${PROXY_USER}\";" >> "$REDSOCKS_CONF"
    echo "    password = \"${PROXY_PASS}\";" >> "$REDSOCKS_CONF"
fi

echo "}" >> "$REDSOCKS_CONF"
chmod 600 "$REDSOCKS_CONF"

# Start redsocks in background
redsocks -c "$REDSOCKS_CONF" &
sleep 1

# ── iptables: redirect all TCP through redsocks ──────────────────────────────
iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS

# Exclude: proxy itself (avoid loop)
iptables -t nat -A REDSOCKS -d "${PROXY_IP}" -j RETURN

# Exclude: local/private ranges
iptables -t nat -A REDSOCKS -d 0.0.0.0/8      -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8     -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8    -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12  -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 224.0.0.0/4    -j RETURN
iptables -t nat -A REDSOCKS -d 240.0.0.0/4    -j RETURN

# Redirect all remaining TCP to redsocks listener
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345

# Apply to outbound traffic
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

# ── DNS leak protection ──────────────────────────────────────────────────────
# Block direct UDP DNS queries — browser resolves DNS via proxy (Camoufox handles this).
# System-level DNS for non-browser processes is blocked to prevent leaks.
iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -A OUTPUT -p tcp --dport 53 -j DROP

echo "[proxy] Transparent proxy active — all TCP routed via ${REDSOCKS_TYPE}://${PROXY_IP}:${PROXY_PORT}"
echo "[proxy] UDP/TCP DNS blocked to prevent leaks"

# ── IPv6 leak protection ─────────────────────────────────────────────────────
# redsocks does not support IPv6 proxying; block all outbound IPv6 to prevent
# traffic bypassing the proxy via IPv6 direct connections.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -A OUTPUT -j DROP
    echo "[proxy] IPv6 outbound blocked to prevent leaks"
else
    echo "[proxy] WARNING: ip6tables not available — IPv6 may leak"
fi