#!/bin/sh
# Dynamic DNS switching for WireGuard.

QUAD9_V4="${WIREGUARD_FALLBACK_DNS:-9.9.9.9 149.112.112.112}"
MULLVAD_DNS="${WIREGUARD_DNS:-100.64.0.23}"

get_phys_iface() {
    ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

set_dns_resolvectl() {
    local iface="$1"; shift
    resolvectl dns "$iface" "$@" 2>/dev/null
}

set_dns_resolvconf() {
    local iface="$1"; shift
    local servers="$*"
    for s in $servers; do
        echo "nameserver $s"
    done | resolvconf -a "tun.${iface}" -m 0 -x 2>/dev/null
}

set_dns_direct() {
    local servers="$*"
    > /etc/resolv.conf
    for s in $servers; do
        echo "nameserver $s"
    done >> /etc/resolv.conf
    echo "options edns0 trust-ad" >> /etc/resolv.conf
}

set_dns_direct_if_regular() {
    [ -L /etc/resolv.conf ] && return 0
    set_dns_direct "$@"
}

set_dns() {
    local iface="$1"; shift
    if command -v resolvectl >/dev/null 2>&1 && set_dns_resolvectl "$iface" "$@"; then
        return 0
    fi
    if command -v resolvconf >/dev/null 2>&1 && set_dns_resolvconf "$iface" "$@"; then
        return 0
    fi
    set_dns_direct "$@"
}

case "${1}" in
    up)
        IFACE="${2}"
        [ -z "$IFACE" ] && { echo "Usage: $0 up <interface>"; exit 1; }
        set_dns "$IFACE" "$MULLVAD_DNS"
        set_dns_direct_if_regular "$MULLVAD_DNS"
        command -v resolvectl >/dev/null 2>&1 && \
            resolvectl default-route "$IFACE" yes 2>/dev/null && \
            resolvectl domain "$IFACE" "~." 2>/dev/null
        echo "DNS: $IFACE -> Mullvad ($MULLVAD_DNS)"
        ;;
    down)
        IFACE="${2}"
        PHYS=$(get_phys_iface)
        [ -z "$PHYS" ] && { echo "Error: no default route interface found"; exit 1; }

        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl revert "$IFACE" 2>/dev/null
            set_dns "$PHYS" $QUAD9_V4
            set_dns_direct_if_regular $QUAD9_V4
        elif command -v resolvconf >/dev/null 2>&1; then
            resolvconf -d "tun.${IFACE}" 2>/dev/null
            set_dns_direct $QUAD9_V4
        else
            set_dns_direct $QUAD9_V4
        fi
        echo "DNS: $PHYS -> Quad9 ($QUAD9_V4)"
        ;;
    *)
        echo "Usage: $0 {up|down} <interface>"
        echo "  up   <iface>   - Set Mullvad DNS on WireGuard interface"
        echo "  down <iface>   - Revert, set Quad9 on physical interface"
        exit 1
        ;;
esac
