#!/bin/sh

CONFIG_DIR="${WIREGUARD_CONFIG_DIR:-/etc/wireguard}"
CGROUP_NAME="wireguard-exclude"
CGROUP_PATH="${WIREGUARD_CGROUP_PATH:-/sys/fs/cgroup/${CGROUP_NAME}}"
NFT_TABLE="wg-exclude"
LAN_NFT_TABLE="wg-lan"
LAN_NFT_SET="blocked_subnets"
DNS_NFT_TABLE="wg-dns"
MULLVAD_DNS="${WIREGUARD_DNS:-100.64.0.23}"

get_default_iface() {
    ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

PHYS_IFACE="$(get_default_iface)"
LAST_FILE="${WIREGUARD_LAST_FILE:-/var/cache/wireguard-last.conf}"
RELAYS_JSON="${WIREGUARD_RELAYS_JSON:-/var/cache/mullvad-relays.json}"
LAN_FILE="${WIREGUARD_LAN_FILE:-/var/cache/wireguard-lan}"
DNS_HELPER="${WIREGUARD_DNS_HELPER:-/usr/local/bin/wireguard-dns.sh}"
NETWORK_TIMEOUT="${WIREGUARD_NETWORK_TIMEOUT:-30}"
USER_WIREGUARD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/wireguard"

if [ -n "${WIREGUARD_DEVICE_JSON:-}" ]; then
    DEVICE_JSON="$WIREGUARD_DEVICE_JSON"
elif [ -r "${USER_WIREGUARD_DIR}/device.json" ]; then
    DEVICE_JSON="${USER_WIREGUARD_DIR}/device.json"
else
    DEVICE_JSON="${CONFIG_DIR}/device.json"
fi

if [ -n "${WIREGUARD_DEFAULT_RELAY_FILE:-}" ]; then
    DEFAULT_RELAY_FILE="$WIREGUARD_DEFAULT_RELAY_FILE"
elif [ -r "${USER_WIREGUARD_DIR}/default-relay" ]; then
    DEFAULT_RELAY_FILE="${USER_WIREGUARD_DIR}/default-relay"
else
    DEFAULT_RELAY_FILE="${CONFIG_DIR}/default-relay"
fi

if [ -n "${WIREGUARD_PRIVILEGE_CMD+x}" ]; then
    DOAS_CMD="$WIREGUARD_PRIVILEGE_CMD"
elif [ "$(id -u)" -eq 0 ]; then
    DOAS_CMD=""
elif command -v doas >/dev/null 2>&1; then
    DOAS_CMD="doas"
else
    DOAS_CMD="sudo"
fi

ns() {
    notify-send "WireGuard" "${1}" 2>/dev/null || true
}

menu() {
    tmp="/tmp/rofi_wg_$$"
    cat > "$tmp"

    x=$(awk -F'\0' '{print length($1)}' "$tmp" | sort -rn | head -1)
    [ -z "$x" ] && x=10

    chk=$(printf '%s' "${1}" | awk '{print length($0)}')
    [ "$x" -lt "$chk" ] && x="$chk"

    x=$((x + 15))

    [ "$x" -lt 30 ] && x=30
    [ "$x" -gt 100 ] && x=100

    cat "$tmp" | rofi -dmenu -i -show-icons -p "${1}" -theme-str "window { width: ${x}ch; }"
    rm -f "$tmp"
}

active_iface() {
    $DOAS_CMD wg show interfaces 2>/dev/null | head -n 1 || echo ""
}

save_last() {
    echo "${1}" | $DOAS_CMD tee "$LAST_FILE" >/dev/null
}

read_last() {
    cat "$LAST_FILE" 2>/dev/null || echo ""
}

read_default() {
    cat "$DEFAULT_RELAY_FILE" 2>/dev/null || echo ""
}

gen_config() {
    hostname="$1"
    path="${CONFIG_DIR}/${hostname}.conf"

    privkey=$($DOAS_CMD jq -r '.logged_in.device.wg_data.private_key' "$DEVICE_JSON") || return 1
    addr4=$($DOAS_CMD jq -r '.logged_in.device.wg_data.addresses.ipv4_address' "$DEVICE_JSON")
    addr6=$($DOAS_CMD jq -r '.logged_in.device.wg_data.addresses.ipv6_address' "$DEVICE_JSON")
    pubkey=$($DOAS_CMD jq -r --arg h "$hostname" '.[] | select(.hostname == $h) | .pubkey' "$RELAYS_JSON")
    endpoint=$($DOAS_CMD jq -r --arg h "$hostname" '.[] | select(.hostname == $h) | .ipv4_addr_in' "$RELAYS_JSON")

    [ -z "$pubkey" ] || [ "$pubkey" = "null" ] && { echo "Relay not found: $hostname" >&2; return 1; }
    [ -z "$endpoint" ] || [ "$endpoint" = "null" ] && { echo "Relay endpoint not found: $hostname" >&2; return 1; }
    [ -z "$privkey" ] || [ "$privkey" = "null" ] && { echo "Device private key not found" >&2; return 1; }
    [ -z "$addr4" ] || [ "$addr4" = "null" ] && { echo "Device IPv4 address not found" >&2; return 1; }
    [ -z "$addr6" ] || [ "$addr6" = "null" ] && { echo "Device IPv6 address not found" >&2; return 1; }

    old_umask=$(umask)
    umask 077
    $DOAS_CMD tee "$path" >/dev/null << INNER_EOF
[Interface]
PrivateKey = ${privkey}
Address = ${addr4}
Address = ${addr6}
PostUp = ${DNS_HELPER} up %i
PostDown = ${DNS_HELPER} down %i

[Peer]
PublicKey = ${pubkey}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}:51820
PersistentKeepalive = 25
INNER_EOF
    ret=$?
    umask "$old_umask"
    [ "$ret" -eq 0 ] || return 1
    $DOAS_CMD chmod 600 "$path" || return 1
}

wg_nft_up() {
    iface="$1"
    fwmark=$($DOAS_CMD wg show "$iface" fwmark 2>/dev/null)
    [ -z "$fwmark" ] || [ "$fwmark" = "off" ] && fwmark="51820"

    wg_cgroup_setup || return 1
    wg_dns_firewall_up || return 1
    $DOAS_CMD nft "add element ip6 ipv6-kill allowed_ifaces { \"$iface\" }" 2>/dev/null || true

    $DOAS_CMD nft -f - << INNER_EOF
table inet $NFT_TABLE {
    chain mark_exclude {
        type route hook output priority filter - 1; policy accept;
        socket cgroupv2 level 1 "${CGROUP_NAME}" ip daddr != ${MULLVAD_DNS} ct mark set 0x00000f41 meta mark set ${fwmark}
        socket cgroupv2 level 1 "${CGROUP_NAME}" meta nfproto ipv6 ct mark set 0x00000f41 meta mark set ${fwmark}
    }
    chain nat_postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ct mark 0x00000f41 oifname != "lo" masquerade
    }
}
INNER_EOF
}

wg_nft_down() {
    wg_dns_firewall_down
    $DOAS_CMD nft flush set ip6 ipv6-kill allowed_ifaces 2>/dev/null || true
    $DOAS_CMD nft delete table inet $NFT_TABLE 2>/dev/null || true
}

wg_dns_firewall_up() {
    $DOAS_CMD nft -f - << INNER_EOF
table inet $DNS_NFT_TABLE
flush table inet $DNS_NFT_TABLE
table inet $DNS_NFT_TABLE {
    chain output {
        type filter hook output priority filter; policy accept;
        udp dport 53 ip daddr $MULLVAD_DNS accept
        tcp dport 53 ip daddr $MULLVAD_DNS accept
        udp dport 53 drop
        tcp dport 53 drop
        udp dport 853 drop
        tcp dport 853 drop
    }
}
INNER_EOF
}

wg_dns_firewall_down() {
    $DOAS_CMD nft delete table inet $DNS_NFT_TABLE 2>/dev/null || true
}

wg_quick_down() {
    iface="$1"
    tmp=$(mktemp) || return 1
    if ! $DOAS_CMD wg-quick down "$iface" >"$tmp" 2>&1; then
        cat "$tmp"
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp"
    rm -f "$tmp"
}

wg_connect() {
    profile="$1"
    [ -z "$profile" ] && return 1

    gen_config "$profile" || { ns "Config not found: ${profile}"; return 1; }

    current=$(active_iface)
    if [ -n "$current" ]; then
        if [ "$current" = "$profile" ]; then
            ns "Already connected to ${profile}"
            return 0
        fi
        if ! wg_quick_down "$current"; then
            ns "Disconnect failed: ${current}"
            return 1
        fi
        wg_nft_down
    fi

    wg_dns_firewall_up || return 1
    tmp=$(mktemp) || return 1
    if ! $DOAS_CMD wg-quick up "$profile" >"$tmp" 2>&1; then
        cat "$tmp"
        rm -f "$tmp"
        wg_dns_firewall_down
        ns "Connect failed: ${profile}"
        return 1
    fi
    cat "$tmp"
    rm -f "$tmp"
    if ! wg_nft_up "$profile"; then
        wg_quick_down "$profile" >/dev/null 2>&1 || true
        ns "Connect failed: nft setup"
        return 1
    fi

    save_last "$profile"
    ns "Connected to ${profile}"
}

wg_connect_menu() {
    countries=$($DOAS_CMD jq -r '
      [.[] | select(.active) |
        (.country_name // .country_code) + " - " + (.city_name // .city_code)
      ] | group_by(.) | .[] | "\(.[0]) (\(length))"' "$RELAYS_JSON" 2>/dev/null | sort) || { ns "Could not read relay list"; return 1; }
    [ -z "$countries" ] && { ns "No relays available"; return 1; }

    sel=$(echo "$countries" | menu "Select country")
    [ -z "$sel" ] && return

    key=$(echo "$sel" | sed 's/ ([0-9]*)$//')

    current=$(active_iface)
    servers=$($DOAS_CMD jq -r --arg k "$key" '
      [.[] | select(.active and
        ((.country_name // .country_code) + " - " + (.city_name // .city_code)) == $k
      ) | .hostname] | .[]' "$RELAYS_JSON" 2>/dev/null | sort)

    [ -z "$servers" ] && { ns "No servers for this location"; return 1; }

    if [ -n "$current" ]; then
        servers=$(echo "$servers" | sed "s/^${current}$/${current}  (connected)/")
    fi

    hostname=$(echo "$servers" | menu "Select server")
    [ -z "$hostname" ] && return

    hostname=$(echo "$hostname" | sed 's/  (connected)$//')

    wg_connect "$hostname"
}

wg_disconnect() {
    current=$(active_iface)
    [ -z "$current" ] && { ns "Already disconnected"; return; }

    if ! wg_quick_down "$current"; then
        ns "Disconnect failed: ${current}"
        return 1
    fi
    wg_nft_down
    ns "Disconnected ${current}"
}

wg_reconnect() {
    last=$(read_last)
    current=$(active_iface)

    if [ -z "$last" ] && [ -z "$current" ]; then
        echo "No previous connection to reconnect"
        return 0
    fi

    target="${last:-$current}"

    if [ -n "$current" ]; then
        if ! wg_quick_down "$current"; then
            ns "Disconnect failed: ${current}"
            return 1
        fi
        wg_nft_down
    fi

    gen_config "$target" || { ns "Reconnect failed: could not generate config"; return 1; }

    wg_dns_firewall_up || return 1
    tmp=$(mktemp) || return 1
    if ! $DOAS_CMD wg-quick up "$target" >"$tmp" 2>&1; then
        cat "$tmp"
        rm -f "$tmp"
        wg_dns_firewall_down
        ns "Reconnect failed: wg-quick"
        return 1
    fi
    cat "$tmp"
    rm -f "$tmp"
    if ! wg_nft_up "$target"; then
        wg_quick_down "$target" >/dev/null 2>&1 || true
        ns "Reconnect failed: nft setup"
        return 1
    fi

    ns "Reconnected to ${target}"
}

wg_wait_network() {
    elapsed=0
    while :; do
        PHYS_IFACE="$(get_default_iface)"
        [ -n "$PHYS_IFACE" ] && return 0
        if [ "$elapsed" -ge "$NETWORK_TIMEOUT" ]; then
            echo "No default network route after ${NETWORK_TIMEOUT}s" >&2
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

wg_autoconnect() {
    wg_wait_network || { ns "Auto-connect failed: network unavailable"; return 1; }

    if [ -n "$(read_last)" ]; then
        wg_reconnect
        return $?
    fi

    target=$(read_default)
    if [ -n "$target" ]; then
        wg_connect "$target"
        return $?
    fi

    wg_reconnect
}

wg_status() {
    ifaces=$(active_iface)
    if [ -z "$ifaces" ]; then
        ns "WireGuard: Disconnected"
        echo "WireGuard: Disconnected"
        return
    fi
    for iface in $ifaces; do
        info=$($DOAS_CMD wg show "$iface" 2>&1)
        ns "${info}"
        echo "${info}"
    done
}

wg_lan_subnet() {
    ip -o -f inet addr show "$PHYS_IFACE" 2>/dev/null | awk '{print $4; exit}'
}

wg_lan_is_allowed() {
    [ ! -f "$LAN_FILE" ] || [ "$(cat "$LAN_FILE")" != "blocked" ]
}

wg_lan_nft_setup() {
    $DOAS_CMD nft list table inet $LAN_NFT_TABLE >/dev/null 2>&1 || \
        $DOAS_CMD nft add table inet $LAN_NFT_TABLE || return 1

    $DOAS_CMD nft list set inet $LAN_NFT_TABLE $LAN_NFT_SET >/dev/null 2>&1 || \
        $DOAS_CMD nft add set inet $LAN_NFT_TABLE $LAN_NFT_SET '{ type ipv4_addr; flags interval; }' || return 1

    $DOAS_CMD nft list chain inet $LAN_NFT_TABLE output >/dev/null 2>&1 || \
        $DOAS_CMD nft add chain inet $LAN_NFT_TABLE output '{ type filter hook output priority filter; policy accept; }' || return 1

    $DOAS_CMD nft -f - << INNER_EOF
flush chain inet $LAN_NFT_TABLE output
add rule inet $LAN_NFT_TABLE output ip daddr @$LAN_NFT_SET drop
INNER_EOF

    $DOAS_CMD nft flush set inet $LAN_NFT_TABLE $LAN_NFT_SET 2>/dev/null || true
    if [ -f "$LAN_FILE" ] && [ "$(cat "$LAN_FILE")" = "blocked" ]; then
        subnet=$(wg_lan_subnet)
        [ -n "$subnet" ] && $DOAS_CMD nft "add element inet $LAN_NFT_TABLE $LAN_NFT_SET { $subnet }" 2>/dev/null || true
    fi
}

wg_lan_allow() {
    wg_lan_nft_setup || { ns "LAN allow failed"; return 1; }
    $DOAS_CMD nft flush set inet $LAN_NFT_TABLE $LAN_NFT_SET 2>/dev/null || true
    echo "allowed" | $DOAS_CMD tee "$LAN_FILE" >/dev/null
    ns "LAN allowed"
}

wg_lan_block() {
    subnet=$(wg_lan_subnet)
    [ -z "$subnet" ] && { ns "Could not detect local subnet"; return 1; }
    wg_lan_nft_setup || { ns "LAN block failed"; return 1; }
    $DOAS_CMD nft flush set inet $LAN_NFT_TABLE $LAN_NFT_SET 2>/dev/null || true
    $DOAS_CMD nft "add element inet $LAN_NFT_TABLE $LAN_NFT_SET { $subnet }" || return 1
    echo "blocked" | $DOAS_CMD tee "$LAN_FILE" >/dev/null
    ns "LAN blocked: ${subnet}"
}

wg_lan_toggle() {
    if wg_lan_is_allowed; then
        wg_lan_block
    else
        wg_lan_allow
    fi
}

wg_update() {
    echo "Fetching relay list from Mullvad API..."
    tmp=$(mktemp)
    curl -sS "https://api.mullvad.net/www/relays/all/" -o "$tmp" || { echo "Download failed"; rm -f "$tmp"; return 1; }
    jq empty "$tmp" 2>/dev/null || { echo "Invalid JSON received"; rm -f "$tmp"; return 1; }

    $DOAS_CMD mv "$tmp" "$RELAYS_JSON"
    count=$($DOAS_CMD jq '[.[] | select(.active)] | length' "$RELAYS_JSON")
    echo "Updated: ${count} active relays saved to $RELAYS_JSON"
    ns "Relay list updated: ${count} servers"
}

wg_menu() {
    current=$(active_iface)

    items="Connect
Reconnect"

    if [ -n "$current" ]; then
        items="${items}
Disconnect"
    fi

    if wg_lan_is_allowed; then
        items="${items}
LAN: Block"
    else
        items="${items}
LAN: Allow"
    fi

    items="${items}
Update Relays
Status"

    if [ -n "$current" ]; then
        prompt="VPN (${current})"
    else
        prompt="VPN"
    fi

    choice=$(echo "$items" | menu "$prompt")
    [ -z "$choice" ] && return

    case "$choice" in
        "Connect") wg_connect_menu ;;
        "Reconnect") wg_reconnect ;;
        "Disconnect") wg_disconnect ;;
        "LAN: Allow"|"LAN: Block") wg_lan_toggle; wg_menu ;;
        "Update Relays") wg_update ;;
        "Status") wg_status; wg_menu ;;
    esac
}

wg_ipv6_kill_setup() {
    $DOAS_CMD nft list table ip6 ipv6-kill >/dev/null 2>&1 || \
        $DOAS_CMD nft add table ip6 ipv6-kill || return 1

    $DOAS_CMD nft list set ip6 ipv6-kill allowed_ifaces >/dev/null 2>&1 || \
        $DOAS_CMD nft add set ip6 ipv6-kill allowed_ifaces '{ type ifname; }' || return 1

    $DOAS_CMD nft list chain ip6 ipv6-kill output >/dev/null 2>&1 || \
        $DOAS_CMD nft add chain ip6 ipv6-kill output '{ type filter hook output priority filter; policy drop; }' || return 1

    $DOAS_CMD nft -f - << "INNER_EOF"
flush chain ip6 ipv6-kill output
add rule ip6 ipv6-kill output oifname @allowed_ifaces accept
add rule ip6 ipv6-kill output oifname "lo" accept
INNER_EOF
}

wg_cgroup_setup() {
    wg_ipv6_kill_setup || return 1
    wg_lan_nft_setup || return 1
    if [ ! -d "/sys/fs/cgroup" ]; then
        $DOAS_CMD mkdir -p /sys/fs/cgroup || return 1
    fi
    if ! grep -q "cgroup2" /proc/mounts; then
        $DOAS_CMD mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
    fi
    if [ ! -d "$CGROUP_PATH" ]; then
        $DOAS_CMD mkdir -p "$CGROUP_PATH" || return 1
    fi
}

wg_exclude() {
    [ $# -eq 0 ] && { echo "Usage: wireguard.sh exclude <command> [args...]"; return 1; }

    wg_cgroup_setup || return 1

    echo $$ | $DOAS_CMD tee "${CGROUP_PATH}/cgroup.procs" >/dev/null || return 1

    exec "$@"
}

wg_setup() {
    wg_cgroup_setup || { echo "Setup failed"; return 1; }
    echo "Setup complete. Usage:"
    echo "  wireguard.sh                    - VPN menu"
    echo "  wireguard.sh connect <hostname> - Connect to Mullvad relay"
    echo "  wireguard.sh disconnect         - Disconnect"
    echo "  wireguard.sh reconnect          - Reconnect to last server"
    echo "  wireguard.sh autoconnect        - Wait for network and reconnect"
    echo "  wireguard.sh status             - Show connection info"
    echo "  wireguard.sh update             - Update relays list from API"
    echo "  wireguard.sh exclude <cmd>      - Run outside VPN via cgroups"
    echo "  wireguard.sh lan-allow          - Allow local subnet access"
    echo "  wireguard.sh lan-block          - Block local subnet access"
    echo "  wireguard.sh lan-toggle         - Toggle local subnet access"
}

case "${1}" in
    status|-s) wg_status ;;
    connect) wg_connect "${2}" ;;
    disconnect) wg_disconnect ;;
    reconnect) wg_reconnect ;;
    autoconnect) wg_autoconnect ;;
    menu) wg_menu ;;
    exclude) shift; wg_exclude "$@" ;;
    update) wg_update ;;
    lan-allow) wg_lan_allow ;;
    lan-block) wg_lan_block ;;
    lan-toggle) wg_lan_toggle ;;
    setup) wg_setup ;;
    -h|--help)
        echo "Usage:"
        echo "  wireguard.sh                    - VPN menu"
        echo "  wireguard.sh connect <hostname> - Connect to Mullvad relay"
        echo "  wireguard.sh disconnect         - Disconnect"
        echo "  wireguard.sh reconnect          - Reconnect to last server"
        echo "  wireguard.sh autoconnect        - Wait for network and reconnect"
        echo "  wireguard.sh status             - Show connection info"
        echo "  wireguard.sh update             - Update relays list from API"
        echo "  wireguard.sh exclude <cmd>      - Run outside VPN via cgroups"
        echo "  wireguard.sh lan-allow          - Allow local subnet access"
        echo "  wireguard.sh lan-block          - Block local subnet access"
        echo "  wireguard.sh lan-toggle         - Toggle local subnet access"
        echo "  wireguard.sh setup              - Initialize cgroups for split tunneling"
        ;;
    *) wg_menu ;;
esac
