#!/bin/sh
# Install local HTTP connectivity-test responder for China-region Nintendo Switch.
# Tested against iStoreOS 24.10.8. Review config.conf before running as root.

set -eu
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
CONFIG_FILE="${1:-$PROJECT_DIR/config.conf}"

log() { printf '[switch-ctest] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Run this script as root on the router."
[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE. Copy config.example to config.conf and edit it first."

# config.conf is an administrator-edited shell config file.
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${ROUTER_LAN_IP:=}"
: "${SWITCH_IP:=}"
: "${HTTP_PORT:=8081}"
: "${TEST_DOMAIN:=ctest.cdn.n.nintendoswitch.cn}"
: "${OPENCLASH_HOSTS_FILE:=/etc/openclash/custom/openclash_custom_hosts.list}"

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    '
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ipv4 "$ROUTER_LAN_IP" || die "ROUTER_LAN_IP is not a valid IPv4 address: $ROUTER_LAN_IP"
valid_ipv4 "$SWITCH_IP" || die "SWITCH_IP is not a valid IPv4 address: $SWITCH_IP"
valid_port "$HTTP_PORT" || die "HTTP_PORT must be between 1 and 65535."
[ "$HTTP_PORT" -ne 80 ] && [ "$HTTP_PORT" -ne 443 ] || die "HTTP_PORT must not be 80 or 443; those ports are commonly used by the router management service."
case "$TEST_DOMAIN" in
    ''|*[!A-Za-z0-9.-]*) die "TEST_DOMAIN contains unsupported characters." ;;
esac
case "$OPENCLASH_HOSTS_FILE" in
    /*) ;;
    *) die "OPENCLASH_HOSTS_FILE must be an absolute path." ;;
esac

[ -x /usr/sbin/uhttpd ] || die "/usr/sbin/uhttpd not found. Install the uHTTPd package first."
[ -f /usr/lib/uhttpd_ucode.so ] || die "uhttpd Ucode module not found at /usr/lib/uhttpd_ucode.so. Install uhttpd-mod-ucode first."
command -v uci >/dev/null 2>&1 || die "uci command not found."
command -v fw4 >/dev/null 2>&1 || die "fw4 command not found. This script expects a firewall4/nftables system."
[ -f /etc/config/firewall ] || die "/etc/config/firewall not found."
[ -f /etc/config/dhcp ] || die "/etc/config/dhcp not found."
[ -f /etc/config/openclash ] || die "/etc/config/openclash not found. This version of the installer expects OpenClash."
uci -q get openclash.config >/dev/null 2>&1 || die "OpenClash UCI section openclash.config was not found. Check your OpenClash installation/version."
uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1 || die "dnsmasq section dhcp.@dnsmasq[0] was not found. Review your DHCP/DNS configuration."

BASE_DIR="/etc/switch-ctest"
HANDLER_FILE="$BASE_DIR/handler.uc"
NFT_FILE="$BASE_DIR/redirect.nft"
INIT_FILE="/etc/init.d/switch-ctest"
STATE_FILE="$BASE_DIR/state"
FIREWALL_SECTION="switch_ctest"
REBIND_VALUE="/$TEST_DOMAIN/"

# Do not overwrite an unrelated firewall include with the same UCI section name.
existing_fw_path="$(uci -q get "firewall.$FIREWALL_SECTION.path" 2>/dev/null || true)"
if [ -n "$existing_fw_path" ] && [ "$existing_fw_path" != "$NFT_FILE" ]; then
    die "firewall.$FIREWALL_SECTION already points to another file ($existing_fw_path). Rename or inspect that section before proceeding."
fi

mkdir -p "$BASE_DIR" "$(dirname -- "$OPENCLASH_HOSTS_FILE")"

# Preserve the original settings on first installation. Re-runs reuse this state.
CFG_ROUTER_LAN_IP="$ROUTER_LAN_IP"
CFG_SWITCH_IP="$SWITCH_IP"
CFG_HTTP_PORT="$HTTP_PORT"
CFG_TEST_DOMAIN="$TEST_DOMAIN"
CFG_OPENCLASH_HOSTS_FILE="$OPENCLASH_HOSTS_FILE"
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ "${ROUTER_LAN_IP:-}" = "$CFG_ROUTER_LAN_IP" ] || die "ROUTER_LAN_IP differs from the existing installation. Uninstall first or restore the original config.conf."
    [ "${SWITCH_IP:-}" = "$CFG_SWITCH_IP" ] || die "SWITCH_IP differs from the existing installation. Uninstall first or restore the original config.conf."
    [ "${HTTP_PORT:-}" = "$CFG_HTTP_PORT" ] || die "HTTP_PORT differs from the existing installation. Uninstall first or restore the original config.conf."
    [ "${TEST_DOMAIN:-}" = "$CFG_TEST_DOMAIN" ] || die "TEST_DOMAIN differs from the existing installation. Uninstall first or restore the original config.conf."
    [ "${OPENCLASH_HOSTS_FILE:-}" = "$CFG_OPENCLASH_HOSTS_FILE" ] || die "OPENCLASH_HOSTS_FILE differs from the existing installation. Uninstall first or restore the original config.conf."
    log "Existing installation state found; preserving the original settings for safe uninstall."
    ROUTER_LAN_IP="$CFG_ROUTER_LAN_IP"
    SWITCH_IP="$CFG_SWITCH_IP"
    HTTP_PORT="$CFG_HTTP_PORT"
    TEST_DOMAIN="$CFG_TEST_DOMAIN"
    OPENCLASH_HOSTS_FILE="$CFG_OPENCLASH_HOSTS_FILE"
else
    CUSTOM_HOST_WAS_SET=0
    CUSTOM_HOST_OLD=""
    if CUSTOM_HOST_OLD="$(uci -q get openclash.config.custom_host 2>/dev/null)"; then
        CUSTOM_HOST_WAS_SET=1
    fi

    REBIND_EXISTED=0
    if uci -q show 'dhcp.@dnsmasq[0].rebind_domain' 2>/dev/null | grep -Fq "$REBIND_VALUE"; then
        REBIND_EXISTED=1
    fi

    HOST_MAPPING_ADDED=0
    HOSTS_FILE_EXISTED=0
    [ -f "$OPENCLASH_HOSTS_FILE" ] && HOSTS_FILE_EXISTED=1
    BACKUP_DIR="/root/switch-ctest-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in /etc/config/firewall /etc/config/dhcp /etc/config/openclash "$OPENCLASH_HOSTS_FILE"; do
        if [ -f "$f" ]; then
            cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
        fi
    done
    log "Original configuration backups saved under $BACKUP_DIR"
fi

# Add or validate the mapping in the OpenClash custom Hosts file.
# Refuse to replace a different existing mapping for the same hostname.
if [ -f "$OPENCLASH_HOSTS_FILE" ] && grep -Fq "$TEST_DOMAIN" "$OPENCLASH_HOSTS_FILE"; then
    existing_line="$(grep -F "$TEST_DOMAIN" "$OPENCLASH_HOSTS_FILE" | head -n 1)"
    case "$existing_line" in
        *"$ROUTER_LAN_IP"*) log "Hosts mapping already exists; leaving it unchanged." ;;
        *) die "A different Hosts entry already contains $TEST_DOMAIN: $existing_line. Resolve it manually before installation." ;;
    esac
else
    touch "$OPENCLASH_HOSTS_FILE"
    tmp_hosts="${OPENCLASH_HOSTS_FILE}.switch-ctest.$$"
    awk -v domain="$TEST_DOMAIN" -v ip="$ROUTER_LAN_IP" '
        BEGIN { in_hosts = 0; inserted = 0 }
        /^hosts:[[:space:]]*$/ {
            print
            in_hosts = 1
            if (!inserted) {
                printf "  '\''%s'\'': %s\n", domain, ip
                inserted = 1
            }
            next
        }
        in_hosts && /^[^[:space:]#][^:]*:/ { in_hosts = 0 }
        { print }
        END {
            if (!inserted) {
                print "hosts:"
                printf "  '\''%s'\'': %s\n", domain, ip
            }
        }
    ' "$OPENCLASH_HOSTS_FILE" > "$tmp_hosts"
    cat "$tmp_hosts" > "$OPENCLASH_HOSTS_FILE"
    rm -f "$tmp_hosts"
    HOST_MAPPING_ADDED=1
    log "Added $TEST_DOMAIN -> $ROUTER_LAN_IP to OpenClash custom Hosts."
fi

# Persist ownership metadata before changing UCI settings.
cat > "$STATE_FILE" <<EOF_STATE
ROUTER_LAN_IP='$ROUTER_LAN_IP'
SWITCH_IP='$SWITCH_IP'
HTTP_PORT='$HTTP_PORT'
CUSTOM_HOST_WAS_SET=$CUSTOM_HOST_WAS_SET
CUSTOM_HOST_OLD='$CUSTOM_HOST_OLD'
REBIND_EXISTED=$REBIND_EXISTED
HOST_MAPPING_ADDED=$HOST_MAPPING_ADDED
HOSTS_FILE_EXISTED=$HOSTS_FILE_EXISTED
TEST_DOMAIN='$TEST_DOMAIN'
REBIND_VALUE='$REBIND_VALUE'
OPENCLASH_HOSTS_FILE='$OPENCLASH_HOSTS_FILE'
EOF_STATE
chmod 600 "$STATE_FILE"

# HTTP response expected by the local connectivity-test flow.
cat > "$HANDLER_FILE" <<'EOF_HANDLER'
{%
'use strict';

global.handle_request = function(env) {
    uhttpd.send("Status: 200 OK\r\n");
    uhttpd.send("Content-Type: text/plain\r\n");
    uhttpd.send("Content-Length: 2\r\n");
    uhttpd.send("Cache-Control: max-age=0, no-cache, no-store\r\n");
    uhttpd.send("Pragma: no-cache\r\n");
    uhttpd.send("X-Organization: Nintendo\r\n");
    uhttpd.send("\r\n");
    uhttpd.send("ok");
};
%}
EOF_HANDLER

# DNAT only the configured Switch's request to the router's TCP 80 port.
cat > "$NFT_FILE" <<EOF_NFT
ip saddr $SWITCH_IP ip daddr $ROUTER_LAN_IP tcp dport 80 counter dnat ip to $ROUTER_LAN_IP:$HTTP_PORT
EOF_NFT

# Dedicated procd service; does not replace or reconfigure the router's main uHTTPd.
cat > "$INIT_FILE" <<EOF_INIT
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/uhttpd \\
        -f \\
        -p $ROUTER_LAN_IP:$HTTP_PORT \\
        -h /www \\
        -o / \\
        -O $HANDLER_FILE
    procd_set_param respawn 3600 5 5
    procd_set_param file $HANDLER_FILE
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF_INIT
chmod +x "$INIT_FILE"

# Enable OpenClash custom Hosts and add a domain-specific dnsmasq Rebinding exception.
uci set openclash.config.custom_host='1'
if ! uci -q show 'dhcp.@dnsmasq[0].rebind_domain' 2>/dev/null | grep -Fq "$REBIND_VALUE"; then
    uci add_list "dhcp.@dnsmasq[0].rebind_domain=$REBIND_VALUE"
fi
uci commit openclash
uci commit dhcp

# Register the nftables include with fw4.
uci -q delete "firewall.$FIREWALL_SECTION" || true
uci set "firewall.$FIREWALL_SECTION=include"
uci set "firewall.$FIREWALL_SECTION.type=nftables"
uci set "firewall.$FIREWALL_SECTION.path=$NFT_FILE"
uci set "firewall.$FIREWALL_SECTION.position=chain-pre"
uci set "firewall.$FIREWALL_SECTION.chain=dstnat_lan"
uci set "firewall.$FIREWALL_SECTION.enabled=1"
uci commit firewall

log "Checking generated firewall rules..."
fw4 check || die "fw4 check failed. Firewall configuration was not reloaded; inspect the error and run the troubleshooting guide."

/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
if [ -x /etc/init.d/openclash ]; then
    /etc/init.d/openclash restart || log "WARNING: OpenClash restart returned an error. Check OpenClash status/logs."
else
    log "WARNING: /etc/init.d/openclash not found; reload OpenClash manually if required."
fi

# Stop any previous procd instance and a matching manually-started test daemon.
/etc/init.d/switch-ctest stop 2>/dev/null || true
for pid in $(ps | awk -v handler="$HANDLER_FILE" 'index($0, "/usr/sbin/uhttpd") && index($0, handler) { print $1 }'); do
    kill "$pid" 2>/dev/null || true
done
sleep 1
/etc/init.d/switch-ctest enable
/etc/init.d/switch-ctest start

log "Installation complete."
log "DNS target: $TEST_DOMAIN -> $ROUTER_LAN_IP"
log "HTTP listener: $ROUTER_LAN_IP:$HTTP_PORT"
log "DNAT match: source $SWITCH_IP, destination $ROUTER_LAN_IP:80"
log "Run: sh $SCRIPT_DIR/diagnose.sh $CONFIG_FILE"
log "Then test from a LAN PC and from the Switch."
