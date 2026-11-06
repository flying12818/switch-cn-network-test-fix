#!/bin/sh
# Read-only diagnostic report for the Switch connectivity-test setup.

set -u
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
CONFIG_FILE="${1:-$PROJECT_DIR/config.conf}"

section() { printf '\n===== %s =====\n' "$*"; }
run_check() {
    label="$1"; shift
    printf '\n-- %s --\n' "$label"
    "$@" 2>&1 || printf '[diagnose] Command returned non-zero: %s\n' "$label"
}

if [ "$(id -u)" != "0" ]; then
    echo "Run as root for a complete report."
    exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
else
    echo "Config file not found: $CONFIG_FILE"
    echo "Using safe display defaults; edit config.example/config.conf as appropriate."
    ROUTER_LAN_IP="192.168.1.1"
    SWITCH_IP="192.168.1.155"
    HTTP_PORT="8081"
    TEST_DOMAIN="ctest.cdn.n.nintendoswitch.cn"
    OPENCLASH_HOSTS_FILE="/etc/openclash/custom/openclash_custom_hosts.list"
fi

: "${ROUTER_LAN_IP:=192.168.1.1}"
: "${SWITCH_IP:=192.168.1.155}"
: "${HTTP_PORT:=8081}"
: "${TEST_DOMAIN:=ctest.cdn.n.nintendoswitch.cn}"
: "${OPENCLASH_HOSTS_FILE:=/etc/openclash/custom/openclash_custom_hosts.list}"

section "Configured values"
printf 'Router LAN IP : %s\n' "$ROUTER_LAN_IP"
printf 'Switch IP     : %s\n' "$SWITCH_IP"
printf 'HTTP port     : %s\n' "$HTTP_PORT"
printf 'Test domain   : %s\n' "$TEST_DOMAIN"
printf 'Hosts file    : %s\n' "$OPENCLASH_HOSTS_FILE"

section "Files and packages"
for f in /usr/sbin/uhttpd /usr/lib/uhttpd_ucode.so /etc/switch-ctest/handler.uc /etc/switch-ctest/redirect.nft /etc/init.d/switch-ctest /etc/rc.d/S99switch-ctest "$OPENCLASH_HOSTS_FILE"; do
    if [ -e "$f" ]; then printf '[OK]   %s\n' "$f"; else printf '[MISS] %s\n' "$f"; fi
done

section "Service process and listener"
ps | grep '[u]httpd' || true
if command -v netstat >/dev/null 2>&1; then
    netstat -lnpt 2>&1 | grep ":$HTTP_PORT" || echo "No listener found on port $HTTP_PORT"
else
    echo "netstat is not installed."
fi
if [ -x /etc/init.d/switch-ctest ]; then
    /etc/init.d/switch-ctest status 2>&1 || true
fi

section "OpenClash and dnsmasq settings"
uci -q get openclash.config.custom_host 2>&1 || true
uci -q show 'dhcp.@dnsmasq[0].rebind_domain' 2>&1 || true
grep -n -F "$TEST_DOMAIN" "$OPENCLASH_HOSTS_FILE" 2>/dev/null || echo "Domain mapping not found in custom Hosts file."

section "DNS resolution from router"
if command -v nslookup >/dev/null 2>&1; then
    nslookup "$TEST_DOMAIN" "$ROUTER_LAN_IP" 2>&1 || true
else
    echo "nslookup is not installed. Test from a LAN PC instead."
fi

section "Firewall include and active nftables rule"
uci -q show firewall.switch_ctest 2>&1 || true
if command -v fw4 >/dev/null 2>&1; then fw4 check 2>&1 || true; fi
if command -v nft >/dev/null 2>&1; then
    nft list chain inet fw4 dstnat_lan 2>&1 | grep -E 'switch|ctest|dport 80|chain' || true
fi

section "Recent related logs"
if command -v logread >/dev/null 2>&1; then
    logread | grep -Ei 'switch-ctest|ctest\.cdn\.n\.nintendoswitch\.cn|rebind|uhttpd' | tail -n 60 || true
fi

section "PC-side HTTP test"
printf 'Run this command from a Windows PC on the same LAN:\n\n'
printf 'curl.exe -i -A "NX NIFM/00" -H "Host: %s" http://%s:%s/\n' "$TEST_DOMAIN" "$ROUTER_LAN_IP" "$HTTP_PORT"
printf '\nExpected: HTTP 200 OK and response body: ok\n'
printf 'For the actual Switch flow, test its network connection and then check whether the nftables counter increases.\n'
