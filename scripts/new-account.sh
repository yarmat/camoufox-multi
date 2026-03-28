#!/bin/bash
set -e

ACCOUNTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/accounts"

echo "=== New Camoufox Account ==="
echo ""

# 1. Account name
read -rp "Account name [e.g. account-1]: " ACCOUNT
if [[ -z "$ACCOUNT" ]]; then
    echo "Error: account name is required"
    exit 1
fi
if [[ -d "$ACCOUNTS_DIR/$ACCOUNT" ]]; then
    echo "Error: account '$ACCOUNT' already exists"
    exit 1
fi

# 2. Proxy type
read -rp "Proxy type (http/socks5) [http]: " PROXY_TYPE
PROXY_TYPE="${PROXY_TYPE:-http}"
if [[ "$PROXY_TYPE" != "http" && "$PROXY_TYPE" != "socks5" ]]; then
    echo "Error: proxy type must be 'http' or 'socks5'"
    exit 1
fi

# 3. Proxy address
echo "  Tip: for a local proxy on your host machine use host.docker.internal instead of 127.0.0.1"
read -rp "Proxy address (host:port): " PROXY_ADDR
if [[ -z "$PROXY_ADDR" ]]; then
    echo "Error: proxy address is required"
    exit 1
fi

# 4. Proxy credentials (optional)
read -rp "Proxy login (Enter to skip): " PROXY_LOGIN
PROXY_URL=""
if [[ -n "$PROXY_LOGIN" ]]; then
    read -rsp "Proxy password: " PROXY_PASS
    echo ""
    PROXY_URL="${PROXY_TYPE}://${PROXY_LOGIN}:${PROXY_PASS}@${PROXY_ADDR}"
else
    PROXY_URL="${PROXY_TYPE}://${PROXY_ADDR}"
fi

# 5. Detect timezone via proxy (ip-api.com sees proxy IP, not local IP)
echo -n "Detecting timezone via proxy... "
GEO_JSON=$(curl -s --max-time 10 --proxy "$PROXY_URL" \
    "http://ip-api.com/json?fields=timezone,country,city" 2>/dev/null)
DETECTED_TZ=$(echo "$GEO_JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('timezone',''))" 2>/dev/null)
if [[ -n "$DETECTED_TZ" ]]; then
    DETECTED_CITY=$(echo "$GEO_JSON" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('city',''), d.get('country',''))" 2>/dev/null)
    echo "→ $DETECTED_TZ ($DETECTED_CITY)"
else
    echo "failed (proxy unreachable or no response)"
    DETECTED_TZ="Europe/Berlin"
fi
read -rp "Timezone [$DETECTED_TZ]: " TZ_INPUT
TZ="${TZ_INPUT:-$DETECTED_TZ}"

# 6. noVNC port — find next free starting from 6901
DEFAULT_PORT=6901
_port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -q ":$1 "
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$1" >/dev/null 2>&1
    else
        return 1  # can't check — assume free
    fi
}
while _port_in_use "$DEFAULT_PORT" || \
      grep -r "^PORT=$DEFAULT_PORT$" "$ACCOUNTS_DIR"/*/\.env &>/dev/null 2>&1; do
    DEFAULT_PORT=$((DEFAULT_PORT + 1))
done
read -rp "noVNC port [$DEFAULT_PORT]: " PORT
PORT="${PORT:-$DEFAULT_PORT}"

# Generate fingerprint seed (fixed per account, random between accounts)
CAM_SEED=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')

# 6. VNC password
DEFAULT_VNC_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
read -rp "VNC password [$DEFAULT_VNC_PW]: " VNC_PW
VNC_PW="${VNC_PW:-$DEFAULT_VNC_PW}"

# 7. Screen resolution
read -rp "Screen resolution WxH [1280x720]: " CAM_SCREEN
CAM_SCREEN="${CAM_SCREEN:-1280x720}"
if ! [[ "$CAM_SCREEN" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "Error: screen must be in WxH format (e.g. 1280x720)"
    exit 1
fi

# 8. OS fingerprint
read -rp "OS fingerprint (windows/macos) [windows]: " CAM_OS
CAM_OS="${CAM_OS:-windows}"
if [[ "$CAM_OS" != "windows" && "$CAM_OS" != "macos" ]]; then
    echo "Error: OS must be 'windows' or 'macos' (linux is not supported by browserforge)"
    exit 1
fi

# Summary
echo ""
echo "--- Summary ---"
echo "  Account : $ACCOUNT"
echo "  Proxy   : $PROXY_URL"
echo "  Port    : $PORT"
echo "  Screen  : $CAM_SCREEN"
echo "  OS      : $CAM_OS"
echo "  TZ      : $TZ"
echo "  VNC pw  : $VNC_PW"
echo "---------------"
read -rp "Create account? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# Create account directory, profile, and shared files folder
mkdir -p "$ACCOUNTS_DIR/$ACCOUNT/profile"
mkdir -p "$ACCOUNTS_DIR/$ACCOUNT/files"

# Write .env file
cat > "$ACCOUNTS_DIR/$ACCOUNT/.env" <<EOF
ACCOUNT=$ACCOUNT
PORT=$PORT
VNC_PW=$VNC_PW
PROXY=$PROXY_URL
PROXY_TYPE=$PROXY_TYPE
CAM_OS=$CAM_OS
CAM_SEED=$CAM_SEED
CAM_SCREEN=$CAM_SCREEN
TZ=$TZ
HOMEPAGE=https://ipleak.net
EOF

echo ""
echo "✓ Account '$ACCOUNT' created at accounts/$ACCOUNT/"
echo "  Start with: make up ACCOUNT=$ACCOUNT"
echo "  Access at : http://localhost:$PORT/vnc.html"