# WireGuard Mullvad Manager

Small POSIX shell manager for Mullvad WireGuard connections, nftables kill
rules, LAN blocking and cgroup-based split tunneling.

## Requirements

`wireguard-tools`, `iproute2`, `nftables`, `jq` and `curl`. The menu also uses
`rofi` and `notify-send`. Split tunneling requires cgroup v2.

## Configuration

Copy `config/device.example.json` to one of these paths and add your Mullvad
device values:

- `~/.config/wireguard/device.json`
- `/etc/wireguard/device.json`

The relay list is downloaded with:

```sh
wireguard.sh update
```

Set a boot relay in `~/.config/wireguard/default-relay` or
`/etc/wireguard/default-relay`. Runtime files stay under `/var/cache` and
generated profiles under `/etc/wireguard`.

## Usage

```sh
wireguard.sh connect se-got-wg-001
wireguard.sh disconnect
wireguard.sh reconnect
wireguard.sh exclude command args
```

`init/systemd` and `init/openrc` contain service definitions. Install
`bin/wireguard.sh` as `/usr/local/bin/wireguard.sh` and the DNS helper as
`/usr/local/bin/wireguard-dns.sh` before enabling either service.

The systemd service refreshes the relay list before each start. The update uses
one API request without retries or extra waits. If downloading, validating or
saving the list fails, it logs a warning and connects using the existing cache.
Inspect service output with `journalctl -u wireguard-autoconnect.service`.

## systemd-networkd

systemd-networkd deletes routing rules it did not create whenever it
reconfigures a link, for example after a short cable drop. wg-quick's rules
carry all traffic into the tunnel, so without them traffic leaves outside the
VPN. When systemd-networkd is running, `connect` and `reconnect` therefore
write `/etc/systemd/networkd.conf.d/wireguard.conf` with
`ManageForeignRoutingPolicyRules=no` and restart systemd-networkd once to
apply it. If that fails, they warn and connect anyway.
