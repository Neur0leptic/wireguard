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
printf '%s\n' "$*" >> "$MOCK_NOTIFY_LOG"
EOF

cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
[ "$#" -eq 4 ]
[ "$1" = "-fsS" ]
[ "$2" = "https://api.mullvad.net/www/relays/all/" ]
[ "$3" = "-o" ]
/usr/bin/cp "$MOCK_CURL_PAYLOAD" "$4"
exit "${MOCK_CURL_STATUS:-0}"
EOF

cat > "$tmp/bin/mktemp" <<'EOF'
#!/bin/sh
case "${MOCK_MKTEMP_FAIL:-}" in
    download) [ "$#" -eq 0 ] && exit 1 ;;
    cache) [ "$#" -gt 0 ] && exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
EOF

cat > "$tmp/bin/cp" <<'EOF'
#!/bin/sh
if [ "${MOCK_CP_FAIL:-0}" = "1" ]; then
    printf '%s\n' 'partial-copy' > "$2"
    exit 1
fi
exec /usr/bin/cp "$@"
EOF

cat > "$tmp/bin/mv" <<'EOF'
#!/bin/sh
[ "${MOCK_MV_FAIL:-0}" = "1" ] && exit 1
exec /usr/bin/mv "$@"
EOF

chmod +x "$tmp/bin/ip" "$tmp/bin/wg" "$tmp/bin/wg-quick" \
    "$tmp/bin/nft" "$tmp/bin/notify-send" "$tmp/bin/curl" \
    "$tmp/bin/mktemp" "$tmp/bin/cp" "$tmp/bin/mv"

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

cp "$tmp/relays.json" "$tmp/old-relays.json"
cat > "$tmp/new-relays.json" <<'EOF'
[
  {
    "hostname": "new-relay",
    "pubkey": "new-public-key",
    "ipv4_addr_in": "192.0.2.20",
    "active": true
  },
  {
    "hostname": "inactive-relay",
    "pubkey": "inactive-public-key",
    "ipv4_addr_in": "192.0.2.30",
    "active": false
  }
]
EOF

printf '%s\n' "test-relay" > "$tmp/default-relay"
: > "$tmp/mock.log"

run_wireguard() {
    env \
        PATH="$tmp/bin:/usr/bin:/bin" \
        HOME="$tmp/home" \
        TMPDIR="$tmp" \
        MOCK_LOG="$tmp/mock.log" \
        MOCK_NOTIFY_LOG="$tmp/notify.log" \
        MOCK_CURL_LOG="$tmp/curl.log" \
        MOCK_CURL_PAYLOAD="${MOCK_CURL_PAYLOAD:-$tmp/new-relays.json}" \
        MOCK_CURL_STATUS="${MOCK_CURL_STATUS:-0}" \
        MOCK_MKTEMP_FAIL="${MOCK_MKTEMP_FAIL:-}" \
        MOCK_CP_FAIL="${MOCK_CP_FAIL:-0}" \
        MOCK_MV_FAIL="${MOCK_MV_FAIL:-0}" \
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

expect_update_failure() {
    : > "$tmp/curl.log"
    : > "$tmp/notify.log"
    if output=$(run_wireguard update 2>&1); then
        echo "relay update unexpectedly succeeded" >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -Fq "WARNING: Relay update failed:"
    printf '%s\n' "$output" | grep -Fq "Keeping the existing relay list."
    cmp -s "$tmp/old-relays.json" "$tmp/relays.json"
    test "$(wc -l < "$tmp/curl.log")" -eq "${1:-1}"
    test -z "$(find "$tmp" -name 'relays.json.*' -print)"
    if printf '%s\n' "$output" | grep -Fq "Updated:" ||
        grep -Fq "Relay list updated:" "$tmp/notify.log"; then
        echo "failed relay update reported success" >&2
        exit 1
    fi
}

MOCK_CURL_STATUS=7 expect_update_failure
MOCK_CURL_STATUS=22 expect_update_failure

printf '%s\n' 'not-json' > "$tmp/invalid.json"
MOCK_CURL_PAYLOAD="$tmp/invalid.json" expect_update_failure
printf '%s\n' '{"error":"unavailable"}' > "$tmp/invalid.json"
MOCK_CURL_PAYLOAD="$tmp/invalid.json" expect_update_failure
printf '%s\n' '[]' > "$tmp/invalid.json"
MOCK_CURL_PAYLOAD="$tmp/invalid.json" expect_update_failure
printf '%s\n' '[{"hostname":"bad-relay","active":"true"}]' > "$tmp/invalid.json"
MOCK_CURL_PAYLOAD="$tmp/invalid.json" expect_update_failure

MOCK_MKTEMP_FAIL=download expect_update_failure 0
MOCK_MKTEMP_FAIL=cache expect_update_failure
MOCK_CP_FAIL=1 expect_update_failure
MOCK_MV_FAIL=1 expect_update_failure

: > "$tmp/curl.log"
: > "$tmp/notify.log"
output=$(run_wireguard update)
printf '%s\n' "$output" | grep -Fq "Updated: 1 active relays saved to"
grep -Fq "Relay list updated: 1 servers" "$tmp/notify.log"
cmp -s "$tmp/new-relays.json" "$tmp/relays.json"
test "$(stat -c '%a' "$tmp/relays.json")" = "600"
test "$(wc -l < "$tmp/curl.log")" -eq 1
test -z "$(find "$tmp" -name 'relays.json.*' -print)"

grep -Fxq 'ExecStartPre=-/usr/local/bin/wireguard.sh update' \
    "$repo_dir/init/systemd/wireguard-autoconnect.service"

echo "All tests passed"
