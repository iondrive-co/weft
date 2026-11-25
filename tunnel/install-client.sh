#!/bin/sh
# Install weft-tunnel on a client machine and make its key (run as root, e.g. `pkexec tunnel/install-client.sh ...`).
#
#   install-client.sh CONFIG.json            install weft-tunnel, its service and CONFIG; make the key; print its
#                                            public half for `./weft.sh tunnel add-peer`
#   install-client.sh CONFIG.json --start    the same, then enable and start weft-tunnel@NAME
#   install-client.sh --remove NAME          stop and disable weft-tunnel@NAME and remove its rules, table and
#                                            interface (its config and key stay)
#
# CONFIG.json comes from `./weft.sh tunnel client-config`. Start only after the server has the peer: until the tunnel
# handshakes, the selected cgroups are refused (fail closed), never sent the normal way.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# WEFT_INSTALL_ROOT is for tests only: a directory the files land under instead of /.
ROOT="${WEFT_INSTALL_ROOT:-}"
ETC=$ROOT/etc/weft/tunnel
BIN=$ROOT/usr/local/sbin/weft-tunnel
UNIT=$ROOT/etc/systemd/system/weft-tunnel@.service

die() { echo "install-client: $*" >&2; exit 1; }
usage() { sed -n '4,11s/^# \{0,1\}//p' "$0"; exit 2; }

[ $# -ge 1 ] || usage
[ "$(id -u)" -eq 0 ] || die "run as root: pkexec $0 $*"

if [ "$1" = "--remove" ]; then
  [ $# -eq 2 ] || usage
  printf '%s' "$2" | grep -Eq '^[a-z0-9][a-z0-9-]{0,9}$' || die "bad tunnel name '$2'"
  systemctl disable --now "weft-tunnel@$2.service" 2>/dev/null || true
  [ -f "$ETC/$2.json" ] && "$BIN" --config "$ETC/$2.json" purge
  echo "install-client: weft-tunnel@$2 stopped, disabled and purged (config and key kept in $ETC)"
  exit 0
fi

config="$1"; start=0
case "${2:-}" in "") ;; --start) start=1 ;; *) usage ;; esac
[ -f "$config" ] || die "no such config: $config"

# The config is checked before anything is installed.
python3 -I "$HERE/weft_tunnel.py" --config "$config" check >/dev/null || die "$config was refused (see above)"
name="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$config")"

if ! command -v wg >/dev/null 2>&1; then
  echo "install-client: installing wireguard-tools"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y wireguard-tools
fi
command -v nft >/dev/null 2>&1 || [ -x /usr/sbin/nft ] || DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y nftables

# The service may not load modules itself (ProtectKernelModules), so wireguard is loaded now and at every boot.
modprobe wireguard
printf 'wireguard\n' > "$ROOT/etc/modules-load.d/weft-tunnel.conf"

install -m 0755 "$HERE/weft_tunnel.py" "$BIN"
install -m 0644 "$HERE/weft-tunnel@.service" "$UNIT"
# The directory and config stay readable so `weft-tunnel exec` works unprivileged; the key alone is root's (0600).
install -d -m 0755 "$ROOT/etc/weft" "$ETC"
if [ -f "$ETC/$name.json" ] && ! cmp -s "$config" "$ETC/$name.json"; then
  cp -p "$ETC/$name.json" "$ETC/$name.json.$(date -u +%Y%m%dT%H%M%SZ).bak"
fi
install -m 0644 "$config" "$ETC/$name.json"
systemctl daemon-reload

pub="$("$BIN" --config "$ETC/$name.json" keygen)"
address="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"].split("/")[0])' "$config")"
echo "install-client: weft-tunnel installed for '$name'. Client public key:"
echo "  $pub"
echo "Admit it on the server (from the weft checkout):"
echo "  ./weft.sh tunnel add-peer $name $pub $address"

if [ "$start" -eq 1 ]; then
  systemctl enable --now "weft-tunnel@$name.service"
  sleep 3
  "$BIN" --config "$ETC/$name.json" status || {
    echo "install-client: the tunnel is not healthy yet (no handshake?); the selected cgroups are refused until it is." >&2
    exit 1
  }
else
  echo "Then start it:"
  echo "  systemctl enable --now weft-tunnel@$name.service"
fi
