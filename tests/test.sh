#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo_dir/bin/wireguard.sh"
dns_helper="$repo_dir/libexec/wireguard-dns.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/config" "$tmp/cgroup" "$tmp/home"

cat > "$tmp/bin/ip" <<'EOF'
#!/bin/sh
[ "${NO_DEFAULT_ROUTE:-0}" = "1" ] && exit 0
case "$*" in
    "route show default") echo "default via 192.0.2.1 dev eth0" ;;
    "-o -f inet addr show eth0") echo "2: eth0 inet 192.0.2.2/24" ;;
esac
EOF

cat > "$tmp/bin/wg" <<'EOF'
#!/bin/sh
[ "$*" = "show interfaces" ] && exit 0
[ "${3:-}" = "fwmark" ] && echo "off"
EOF

cat > "$tmp/bin/wg-quick" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$tmp/bin/nft" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$tmp/bin/notify-send" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$tmp/bin/ip" "$tmp/bin/wg" "$tmp/bin/wg-quick" \
    "$tmp/bin/nft" "$tmp/bin/notify-send"

cat > "$tmp/device.json" <<'EOF'
{
  "logged_in": {
    "device": {
      "wg_data": {
        "private_key": "test-private-key",
        "addresses": {
          "ipv4_address": "10.64.0.2/32",
          "ipv6_address": "fc00::2/128"
        }
      }
    }
  }
}
EOF

cat > "$tmp/relays.json" <<'EOF'
[
  {
    "hostname": "test-relay",
    "pubkey": "test-public-key",
    "ipv4_addr_in": "192.0.2.10",
    "active": true
  }
]
EOF

printf '%s\n' "test-relay" > "$tmp/default-relay"
: > "$tmp/mock.log"

run_wireguard() {
    env \
        PATH="$tmp/bin:/usr/bin:/bin" \
        HOME="$tmp/home" \
        MOCK_LOG="$tmp/mock.log" \
        NO_DEFAULT_ROUTE="${NO_DEFAULT_ROUTE:-0}" \
        WIREGUARD_PRIVILEGE_CMD="" \
        WIREGUARD_CONFIG_DIR="$tmp/config" \
        WIREGUARD_CGROUP_PATH="$tmp/cgroup" \
        WIREGUARD_DEVICE_JSON="$tmp/device.json" \
        WIREGUARD_RELAYS_JSON="$tmp/relays.json" \
        WIREGUARD_LAST_FILE="$tmp/last" \
        WIREGUARD_LAN_FILE="$tmp/lan" \
        WIREGUARD_DEFAULT_RELAY_FILE="$tmp/default-relay" \
        WIREGUARD_DNS_HELPER="/usr/local/bin/wireguard-dns.sh" \
        WIREGUARD_NETWORK_TIMEOUT="${WIREGUARD_NETWORK_TIMEOUT:-30}" \
        "$script" "$@"
}

dash -n "$script"
dash -n "$dns_helper"
dash -n "$repo_dir/init/openrc/wireguard-autoconnect"

run_wireguard autoconnect

test "$(cat "$tmp/last")" = "test-relay"
test "$(stat -c '%a' "$tmp/config/test-relay.conf")" = "600"
grep -Fq "PrivateKey = test-private-key" "$tmp/config/test-relay.conf"
grep -Fq "PostUp = /usr/local/bin/wireguard-dns.sh up %i" "$tmp/config/test-relay.conf"
grep -Fq "Endpoint = 192.0.2.10:51820" "$tmp/config/test-relay.conf"
grep -Fq "up test-relay" "$tmp/mock.log"

output=$(env \
    PATH="$tmp/bin:/usr/bin:/bin" \
    HOME="$tmp/home" \
    WIREGUARD_PRIVILEGE_CMD="" \
    WIREGUARD_LAST_FILE="$tmp/missing-last" \
    "$script" reconnect)
test "$output" = "No previous connection to reconnect"

run_wireguard --help | grep -Fq "wireguard.sh autoconnect"

if NO_DEFAULT_ROUTE=1 WIREGUARD_NETWORK_TIMEOUT=0 run_wireguard autoconnect; then
    echo "autoconnect unexpectedly succeeded without a default route" >&2
    exit 1
fi

echo "All tests passed"
