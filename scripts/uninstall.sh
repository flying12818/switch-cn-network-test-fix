#!/bin/sh
# Remove the Switch connectivity-test configuration installed by install.sh.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BASE_DIR="/etc/switch-ctest"
STATE_FILE="$BASE_DIR/state"
FIREWALL_SECTION="switch_ctest"

log() { printf '[switch-ctest] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Run this script as root on the router."
[ -f "$STATE_FILE" ] || die "Installation state file not found ($STATE_FILE). Refusing to guess which DNS/Hosts settings belong to this project."

# State file is generated locally by install.sh and contains only simple assignments.
# shellcheck disable=SC1090
. "$STATE_FILE"
: "${TEST_DOMAIN:=}"
: "${REBIND_VALUE:=/$TEST_DOMAIN/}"
: "${OPENCLASH_HOSTS_FILE:=/etc/openclash/custom/openclash_custom_hosts.list}"
: "${CUSTOM_HOST_WAS_SET:=0}"
: "${CUSTOM_HOST_OLD:=}"
: "${REBIND_EXISTED:=0}"
 : "${HOST_MAPPING_ADDED:=0}"
: "${HOSTS_FILE_EXISTED:=1}"
: "${ROUTER_LAN_IP:=}"
: "${SWITCH_IP:=}"
: "${HTTP_PORT:=}"

[ -n "$TEST_DOMAIN" ] || die "Invalid state file: TEST_DOMAIN is empty."

owned_fw_path="$(uci -q get firewall.$FIREWALL_SECTION.path 2>/dev/null || true)"
if [ -n "$owned_fw_path" ] && [ "$owned_fw_path" != "/etc/switch-ctest/redirect.nft" ]; then
    die "firewall.$FIREWALL_SECTION now points to another file ($owned_fw_path). Refusing to remove a section that may have been repurposed."
fi

if [ -x /etc/init.d/switch-ctest ]; then
    /etc/init.d/switch-ctest stop || true
    /etc/init.d/switch-ctest disable || true
fi

# Remove only this project's named firewall include.
uci -q delete "firewall.$FIREWALL_SECTION" || true
uci commit firewall
if command -v fw4 >/dev/null 2>&1; then
    fw4 check && /etc/init.d/firewall reload || log "WARNING: firewall check/reload reported an error; inspect the firewall before further changes."
fi

# Remove the dnsmasq exception only if it did not exist before installation.
if [ "$REBIND_EXISTED" = "0" ] && [ -f /etc/config/dhcp ]; then
    uci -q del_list "dhcp.@dnsmasq[0].rebind_domain=$REBIND_VALUE" || true
    uci commit dhcp
fi

# Remove the OpenClash mapping only if this installer added it.
if [ "$HOST_MAPPING_ADDED" = "1" ] && [ -f "$OPENCLASH_HOSTS_FILE" ]; then
    tmp_hosts="${OPENCLASH_HOSTS_FILE}.switch-ctest.$$"
    awk -v domain="$TEST_DOMAIN" -v ip="$ROUTER_LAN_IP" '
        BEGIN { in_hosts = 0 }
        /^hosts:[[:space:]]*$/ { in_hosts = 1; print; next }
        in_hosts && /^[^[:space:]#][^:]*:/ { in_hosts = 0 }
        in_hosts && index($0, domain) > 0 && index($0, ip) > 0 { next }
        { print }
    ' "$OPENCLASH_HOSTS_FILE" > "$tmp_hosts"
    cat "$tmp_hosts" > "$OPENCLASH_HOSTS_FILE"
    rm -f "$tmp_hosts"
fi

# If this installer created the Hosts file, remove it only when it is otherwise empty.
if [ "$HOSTS_FILE_EXISTED" = "0" ] && [ -f "$OPENCLASH_HOSTS_FILE" ]; then
    if ! grep -Ev '^[[:space:]]*(#|$|hosts:[[:space:]]*$)' "$OPENCLASH_HOSTS_FILE" >/dev/null 2>&1; then
        rm -f "$OPENCLASH_HOSTS_FILE"
    fi
fi

# Restore the OpenClash custom-Hosts toggle to its pre-install value.
if [ -f /etc/config/openclash ]; then
    current_custom_host="$(uci -q get openclash.config.custom_host 2>/dev/null || true)"
    if [ "$current_custom_host" = "1" ]; then
        if [ "$CUSTOM_HOST_WAS_SET" = "1" ]; then
            uci set "openclash.config.custom_host=$CUSTOM_HOST_OLD"
        else
            uci -q delete openclash.config.custom_host || true
        fi
        uci commit openclash
    else
        log "OpenClash custom_host is no longer 1; leaving its current value unchanged."
    fi
fi

/etc/init.d/dnsmasq restart || log "WARNING: dnsmasq restart reported an error."
if [ -x /etc/init.d/openclash ]; then
    /etc/init.d/openclash restart || log "WARNING: OpenClash restart reported an error."
fi

rm -f /etc/init.d/switch-ctest
rm -rf "$BASE_DIR"

log "Uninstall complete. Original configuration backups, if created, remain under /root/switch-ctest-backup-*/."
log "The router's main uHTTPd/LuCI service was not changed."
