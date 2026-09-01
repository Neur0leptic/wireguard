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
