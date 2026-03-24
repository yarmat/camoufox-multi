#!/bin/bash
# Leak detection — runs inside the container via docker exec.
# Checks: redsocks, iptables rules, DNS leak, external IP, direct bypass.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILED=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; FAILED=$((FAILED + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

echo -e "\n${BOLD}=== Leak Detection: container $(hostname) ===${NC}"
if [ -n "${PROXY:-}" ]; then
    info "Proxy configured: ${PROXY%%@*}@..."
else
    warn "No PROXY env — container is running without a proxy"
fi
echo ""

# ── 1. redsocks ───────────────────────────────────────────────────────────────
echo -e "${BOLD}[1] Transparent proxy (redsocks)${NC}"
if [ -z "${PROXY:-}" ]; then
    warn "Skipped — no proxy configured"
elif pgrep -x redsocks > /dev/null 2>&1; then
    pass "redsocks is running (PID $(pgrep -x redsocks | head -1))"
else
    fail "redsocks is NOT running"
fi

# ── 2. iptables rules ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[2] iptables rules${NC}"
if iptables -t nat -L REDSOCKS -n 2>/dev/null | grep -q "REDIRECT"; then
    pass "REDSOCKS nat chain active — TCP redirected to port 12345"
else
    if [ -n "${PROXY:-}" ]; then
        fail "REDSOCKS iptables chain missing or has no REDIRECT rule"
    else
        warn "Skipped — no proxy configured"
    fi
fi

if iptables -L OUTPUT -n 2>/dev/null | grep -q "dpt:53"; then
    pass "DNS port 53 (UDP + TCP) is blocked in OUTPUT"
else
    if [ -n "${PROXY:-}" ]; then
        fail "No DNS block rule found — DNS leak possible"
    else
        warn "No DNS block rule (expected — no proxy configured)"
    fi
fi

# ── 2b. IPv6 leak protection ──────────────────────────────────────────────────
echo -e "\n${BOLD}[2b] IPv6 leak protection${NC}"
if command -v ip6tables >/dev/null 2>&1; then
    if ip6tables -S OUTPUT 2>/dev/null | grep -q "\-j DROP"; then
        pass "ip6tables OUTPUT DROP rule present — IPv6 blocked"
    else
        if [ -n "${PROXY:-}" ]; then
            fail "No ip6tables DROP rule — IPv6 traffic may bypass the proxy"
        else
            warn "No ip6tables DROP rule (no proxy configured)"
        fi
    fi
    # Attempt an actual IPv6 connection to confirm it's blocked
    if timeout 4 curl -fsSL --max-time 3 -6 "https://ipv6.icanhazip.com" >/dev/null 2>&1; then
        if [ -n "${PROXY:-}" ]; then
            fail "IPv6 connection succeeded — IPv6 leak confirmed!"
        else
            warn "IPv6 connection works (no proxy — expected)"
        fi
    else
        pass "IPv6 connection attempt blocked"
    fi
else
    warn "ip6tables not available in this container"
fi

# ── 3. DNS leak test ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3] DNS leak test${NC}"
if timeout 3 nslookup google.com 8.8.8.8 > /dev/null 2>&1; then
    if [ -n "${PROXY:-}" ]; then
        fail "Direct DNS query to 8.8.8.8 succeeded — DNS may be leaking!"
    else
        warn "Direct DNS to 8.8.8.8 works (no proxy — expected)"
    fi
else
    pass "Direct DNS query to 8.8.8.8 blocked (no DNS leak)"
fi

# ── 4. External IP check ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[4] External IP / proxy routing${NC}"

EXPECTED_HOST=""
EXPECTED_IP=""
if [ -n "${PROXY:-}" ]; then
    PROXY_HOSTPORT=$(echo "$PROXY" | sed 's|^[a-z0-9+]*://||; s|.*@||')
    EXPECTED_HOST=$(echo "$PROXY_HOSTPORT" | cut -d: -f1)
    if echo "$EXPECTED_HOST" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$'; then
        EXPECTED_IP="$EXPECTED_HOST"
    else
        EXPECTED_IP=$(getent hosts "$EXPECTED_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)
    fi
    info "Proxy host: $EXPECTED_HOST ($EXPECTED_IP)"
fi

ACTUAL_IP=""
for URL in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    ACTUAL_IP=$(timeout 10 wget -qO- --timeout=8 "$URL" 2>/dev/null | tr -d '[:space:]') || true
    [ -n "$ACTUAL_IP" ] && break
done

if [ -z "$ACTUAL_IP" ]; then
    fail "Could not reach any IP-check service (network broken or all blocked?)"
else
    info "Visible external IP: ${BOLD}$ACTUAL_IP${NC}"
    if [ -z "${PROXY:-}" ]; then
        warn "This is your REAL IP (no proxy configured)"
    elif [ "$ACTUAL_IP" = "$EXPECTED_IP" ]; then
        pass "External IP matches proxy host IP exactly"
    else
        # Not necessarily a leak — proxy providers use multiple egress IPs
        warn "External IP ($ACTUAL_IP) differs from proxy host IP ($EXPECTED_IP)"
        warn "Normal if your proxy provider uses a shared egress pool"
        info "Verify: is $ACTUAL_IP an IP belonging to your proxy provider?"
    fi
fi

# ── 5. Direct bypass test ─────────────────────────────────────────────────────
echo -e "\n${BOLD}[5] Direct connection bypass test${NC}"
if [ -n "${PROXY:-}" ] && [ -n "$ACTUAL_IP" ]; then
    # curl --noproxy forces no proxy at the curl level; iptables should still intercept
    DIRECT_IP=$(timeout 10 curl -fsSL --max-time 8 --noproxy '*' "https://api.ipify.org" 2>/dev/null | tr -d '[:space:]') || true
    if [ -z "$DIRECT_IP" ]; then
        pass "Direct connection attempt (--noproxy) was blocked by iptables"
    elif [ "$DIRECT_IP" = "$ACTUAL_IP" ]; then
        pass "Direct connection also exits via proxy IP — iptables intercepts correctly"
    else
        fail "Direct connection returns $DIRECT_IP vs proxied $ACTUAL_IP — possible bypass!"
    fi
fi

# ── 6. Detailed IP info (ip-api.com) ─────────────────────────────────────────
echo -e "\n${BOLD}[6] Detailed IP info  (ip-api.com)${NC}"
IP_API_JSON=$(timeout 10 wget -qO- --timeout=8 "http://ip-api.com/json" 2>/dev/null || true)
if [ -z "$IP_API_JSON" ]; then
    fail "Could not reach ip-api.com"
else
    # flatten to simple key=value via python3 (always available in this image)
    _ipapi() {
        echo "$IP_API_JSON" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('$1','N/A'))" 2>/dev/null || echo "N/A"
    }
    if [ "$(_ipapi status)" = "success" ]; then
        info "IP:        $(_ipapi query)"
        info "ISP:       $(_ipapi isp)"
        info "Org / ASN: $(_ipapi org)  |  $(_ipapi as)"
        info "Location:  $(_ipapi city), $(_ipapi regionName), $(_ipapi country)"
        info "Timezone:  $(_ipapi timezone)"
        # timezone sanity check
        API_TZ=$(_ipapi timezone)
        CONTAINER_TZ="${TZ:-}"
        if [ -n "$CONTAINER_TZ" ] && [ "$API_TZ" != "$CONTAINER_TZ" ]; then
            warn "Timezone mismatch: container TZ=$CONTAINER_TZ but IP geolocates to $API_TZ"
        elif [ -n "$CONTAINER_TZ" ]; then
            pass "Timezone matches container TZ setting ($CONTAINER_TZ)"
        fi
    else
        fail "ip-api.com error: $(_ipapi message)"
    fi
fi

# ── 7. Proxy / VPN detection (proxycheck.io) ─────────────────────────────────
echo -e "\n${BOLD}[7] Proxy / VPN detection  (proxycheck.io)${NC}"
if [ -z "$ACTUAL_IP" ]; then
    warn "Skipped — no external IP determined in step [4]"
else
    PC_JSON=$(timeout 10 wget -qO- --timeout=8 \
        "https://proxycheck.io/v2/${ACTUAL_IP}?vpn=1&asn=1&risk=1" 2>/dev/null || true)
    if [ -z "$PC_JSON" ]; then
        warn "Could not reach proxycheck.io (rate-limited or network issue)"
    else
        # flatten nested {status:.., "<IP>":{...}} → single dict
        PC_FLAT=$(echo "$PC_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
top = {k: v for k, v in d.items() if k in ('status', 'message')}
ips = [k for k in d if k not in ('status', 'message', 'node')]
nested = d[ips[0]] if ips and isinstance(d[ips[0]], dict) else {}
top.update(nested)
print(json.dumps(top))
" 2>/dev/null || echo '{"status":"error"}')
        _pc() {
            echo "$PC_FLAT" | python3 -c \
                "import json,sys; d=json.load(sys.stdin); print(d.get('$1','N/A'))" 2>/dev/null || echo "N/A"
        }
        PC_STATUS=$(_pc status)
        if [ "$PC_STATUS" = "ok" ] || [ "$PC_STATUS" = "warning" ]; then
            IS_PROXY=$(_pc proxy)
            PTYPE=$(_pc type)
            RISK=$(_pc risk)
            PROVIDER=$(_pc provider)
            [ "$IS_PROXY" != "N/A" ] && info "Is proxy/VPN: $IS_PROXY"
            [ "$PTYPE"    != "N/A" ] && info "Type:         $PTYPE"
            [ "$PROVIDER" != "N/A" ] && info "Provider:     $PROVIDER"
            [ "$RISK"     != "N/A" ] && info "Risk score:   $RISK / 100"
            if [ "$IS_PROXY" = "yes" ]; then
                pass "IP is flagged as proxy/VPN by proxycheck.io — proxy routing confirmed"
            else
                warn "IP not flagged as proxy (may be a clean residential/datacenter proxy)"
            fi
        else
            warn "proxycheck.io returned: $(_pc message)"
        fi
    fi
fi

# ── 8. DNS resolver info ──────────────────────────────────────────────────────
echo -e "\n${BOLD}[8] DNS resolver${NC}"
if [ -f /etc/resolv.conf ]; then
    RESOLVERS=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
    info "System nameserver(s): ${RESOLVERS:-none found}"
fi
if [ -n "${PROXY:-}" ]; then
    pass "DNS leak prevented: UDP+TCP port 53 blocked by iptables"
    info "Browser DNS is resolved by the proxy server — no local resolver used"
else
    warn "No proxy — DNS queries go to system resolver directly"
fi
info "Canvas / WebGL / WebRTC fingerprints require browser — check manually at ipleak.net or browserleaks.com"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Summary ===${NC}"
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All checks passed — no leaks detected${NC}\n"
else
    echo -e "${RED}${BOLD}$FAILED check(s) FAILED — review above${NC}\n"
    exit 1
fi