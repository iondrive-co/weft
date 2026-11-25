#!/usr/bin/env bash
# End-to-end test of the weft tunnel without root and without touching this machine's network.
#
# Builds three network namespaces inside one user namespace, joined by veth pairs:
#
#   client                       5.5.5.2 --- 5.5.5.1  server  9.9.9.1 --- 9.9.9.2  internet (+ 9.9.9.6, 192.168.77.1)
#
# The server runs the real egress.nft (from egress.nft.tftpl), a wg0.conf written the way cloud-init writes it,
# wg-quick, and weft-peer to admit the client. The client runs weft_tunnel.py with a cgroup of this user's systemd
# manager (wefttest.slice) selected. A TCP probe asks a listener in "internet" which source address it saw:
# 9.9.9.1 means the tunnel (masqueraded by the server), 5.5.5.2 means the client's normal route.
#
# Needs: unshare, nsenter, systemd-run --user, nft, python3, and wg + wg-quick on PATH (or WG_BIN=dir).
# Exits 77 (skip) when a prerequisite is missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${WG_BIN:-}" ] && PATH="$WG_BIN:$PATH"
PATH="$PATH:/usr/sbin:/sbin"
for t in unshare nsenter systemd-run nft python3 wg wg-quick ip; do
  command -v "$t" >/dev/null || { echo "skip: $t not found"; exit 77; }
done
[ "$(id -u)" -ne 0 ] || { echo "skip: run as an ordinary user (the test uses this user's systemd slices)"; exit 77; }
systemctl --user is-system-running >/dev/null 2>&1 || [ $? -le 1 ] || { echo "skip: no systemd user manager"; exit 77; }

uid="$(id -u)"
SLICE="wefttest$$.slice"
CG="user.slice/user-$uid.slice/user@$uid.service/$SLICE"
W="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  systemctl --user stop "$SLICE" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# --- namespaces: one user namespace, three network namespaces ---
unshare -Urn sleep infinity & C=$!; pids+=("$C")
sleep 0.2
in_c() { nsenter --preserve-credentials -t "$C" -U -n "$@"; }
# Background jobs are run as plain commands (not functions) so $! is the process itself, not a subshell.
NSC=(nsenter --preserve-credentials -t "$C" -U -n)
"${NSC[@]}" unshare -n sleep infinity & S=$!; pids+=("$S")
"${NSC[@]}" unshare -n sleep infinity & I=$!; pids+=("$I")
sleep 0.2
in_s() { nsenter --preserve-credentials -t "$S" -U -n "$@"; }
in_i() { nsenter --preserve-credentials -t "$I" -U -n "$@"; }

in_c ip link set lo up; in_s ip link set lo up; in_i ip link set lo up
in_c ip link add c0 type veth peer name s0 netns "$S"
in_s ip link add s1 type veth peer name i0 netns "$I"
in_c ip addr add 5.5.5.2/30 dev c0; in_c ip link set c0 up; in_c ip route add default via 5.5.5.1
in_s ip addr add 5.5.5.1/30 dev s0; in_s ip link set s0 up
in_s ip addr add 9.9.9.1/30 dev s1; in_s ip link set s1 up
in_s ip route add 9.9.9.6/32 via 9.9.9.2; in_s ip route add 192.168.77.0/24 via 9.9.9.2
in_i ip addr add 9.9.9.2/30 dev i0; in_i ip addr add 9.9.9.6/32 dev i0; in_i ip addr add 192.168.77.1/24 dev i0
in_i ip link set i0 up; in_i ip route add 5.5.5.0/30 via 9.9.9.1
in_s sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
# The health probe uses an unprivileged ICMP socket, which a new network namespace refuses by default.
in_c sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'  # only gid 0 is mapped here

# --- "internet": tells each TCP client the address it came from ---
cat > "$W/whoami.py" <<'EOF'
import socketserver
class H(socketserver.BaseRequestHandler):
    def handle(self): self.request.sendall(self.client_address[0].encode())
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", 8080), H).serve_forever()
EOF
nsenter --preserve-credentials -t "$I" -U -n python3 -I "$W/whoami.py" & pids+=("$!")

cat > "$W/probe.py" <<'EOF'
import socket, sys
host, src = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
try:
    s = socket.create_connection((host, 8080), timeout=3, source_address=(src, 0) if src else None)
    print(s.recv(64).decode())
except OSError as e:
    print(f"error:{e.errno or type(e).__name__}")
EOF
# probe [selected|plain] HOST [SOURCE]: prints the source the listener saw, or error:ERRNO
probe() {
  local who="$1"; shift
  if [ "$who" = selected ]; then
    systemd-run --user --scope --quiet --collect --slice="$SLICE" -- nsenter --preserve-credentials -t "$C" -U -n python3 -I "$W/probe.py" "$@"
  else
    in_c python3 -I "$W/probe.py" "$@"
  fi
}
expect() {  # expect DESCRIPTION WANT GOT
  if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1: wanted $2, got $3"; fi
}

# --- server: the files cloud-init writes, then weft-peer admits the client ---
mkdir -p "$W/srv"
sed 's|${tunnel_cidr}|10.77.0.0/24|' "$HERE/egress.nft.tftpl" > "$W/srv/egress.nft"
grep -q '\${' "$W/srv/egress.nft" && { bad "egress.nft.tftpl has a placeholder the test does not fill"; exit 1; }
in_s nft -f "$W/srv/egress.nft"
in_s nft -f "$W/srv/egress.nft"   # loading twice must replace, not fail or duplicate
umask 077
wg genkey > "$W/srv/server.key"; wg pubkey < "$W/srv/server.key" > "$W/srv/server.pub"
printf '%s\n' '[Interface]' 'Address = 10.77.0.1/24' 'ListenPort = 51820' \
  "PostUp = wg set %i private-key $W/srv/server.key" > "$W/srv/wg0.conf"
in_s wg-quick up "$W/srv/wg0.conf" >/dev/null 2>&1 || { bad "wg-quick up on the server"; exit 1; }

# --- client ---
mkdir -p "$W/cli"
cat > "$W/cli/t.json" <<EOF
{"name": "t", "endpoint": "5.5.5.1:51820", "server_public_key": "$(cat "$W/srv/server.pub")",
 "address": "10.77.0.2/24", "cgroups": ["$CG"], "bypass": ["9.9.9.6"],
 "private_key_file": "$W/cli/t.key"}
EOF
tun() { in_c python3 -I "$HERE/weft_tunnel.py" --config "$W/cli/t.json" "$@"; }
cpub="$(tun keygen)"
[ "$(stat -c %a "$W/cli/t.key")" = 600 ] && ok "client key is 0600" || bad "client key mode $(stat -c %a "$W/cli/t.key")"
[ "$(tun keygen)" = "$cpub" ] && ok "keygen keeps an existing key" || bad "keygen replaced the key"
WEFT_WG_DIR="$W/srv" in_s sh "$HERE/weft-peer" add laptop "$cpub" 10.77.0.2 >/dev/null
in_s wg show wg0 allowed-ips | grep -q "10.77.0.2/32" && ok "weft-peer applied the client live" \
  || bad "weft-peer did not reach the running wg0"
in_s wg show wg0 private-key | grep -q . && ok "weft-peer kept the server's private key" \
  || bad "weft-peer cleared the server's private key"

# A unit keeps the slice (and so its cgroup) alive, as long-running services keep theirs.
systemd-run --user --quiet --collect --slice="$SLICE" --unit="wefttest$$-keep" sleep 600
for _ in $(seq 50); do [ -d "/sys/fs/cgroup/$CG" ] && break; sleep 0.1; done

tun up >/dev/null
for _ in $(seq 30); do in_c wg show weft-t latest-handshakes | awk '{exit !($2>0)}' && break; sleep 0.2; done

if [ -n "${DEBUG:-}" ]; then
  tun status || true; in_c wg show; in_s wg show; in_c ip rule show; in_c ip route show table 30777
  in_c ip addr show weft-t; in_c nft list table inet weft_t; in_s ip route; in_s nft list ruleset | head -60
fi
expect "selected process" 9.9.9.1 "$(probe selected 9.9.9.2)"
expect "other process" 5.5.5.2 "$(probe plain 9.9.9.2)"
expect "other process bound to the tunnel address" 9.9.9.1 "$(probe plain 9.9.9.2 10.77.0.2)"
expect "selected process to a bypass address" 5.5.5.2 "$(probe selected 9.9.9.6)"
# The server forwards tunnel clients to public space only.
expect "tunnel to private space is dropped by the server" error:TimeoutError "$(probe plain 192.168.77.1 10.77.0.2)"
expect "same private address on the normal route" 5.5.5.2 "$(probe plain 192.168.77.1)"
tun status >/dev/null && ok "status reports healthy" || bad "status not healthy after up"

# Fail closed: without the interface, selected traffic is refused instead of leaving by the normal route.
tun down
got="$(probe selected 9.9.9.2)"
case "$got" in error:111|error:113) ok "selected process with the tunnel down is refused at once -> $got" ;;
  *) bad "selected process with the tunnel down: wanted an immediate refusal, got $got" ;; esac
expect "bound to the tunnel address with the tunnel down" error:99 "$(probe plain 9.9.9.2 10.77.0.2)"
expect "other process with the tunnel down" 5.5.5.2 "$(probe plain 9.9.9.2)"
tun status >/dev/null && bad "status healthy with the interface down" || ok "status unhealthy with the interface down"

# The service loop puts back what disappears.
"${NSC[@]}" python3 -I "$HERE/weft_tunnel.py" --config "$W/cli/t.json" --interval 0.3 run > "$W/run.log" 2>&1 & RUN=$!; pids+=("$RUN")
sleep 1.5
expect "run brought the tunnel back" 9.9.9.1 "$(probe selected 9.9.9.2)"
in_c nft delete table inet weft_t
in_c ip rule del priority 5270
sleep 1.2
grep -q '"restored"' "$W/run.log" && ok "run logged a restore" || bad "run did not log a restore"
expect "after nft table and rule were deleted" 9.9.9.1 "$(probe selected 9.9.9.2)"
in_c ip link del weft-t
sleep 1.5
expect "after the interface was deleted" 9.9.9.1 "$(probe selected 9.9.9.2)"
# Stopping the service (SIGTERM, as systemd does) closes the tunnel rather than leaving it open or leaking.
kill -TERM "$RUN"; wait "$RUN"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"stopped": "SIGTERM", "mode": "closed"' "$W/run.log" && ok "SIGTERM stops run cleanly, closed" \
  || bad "run on SIGTERM: rc=$rc, log: $(tail -n 2 "$W/run.log")"
in_c ip link show weft-t >/dev/null 2>&1 && bad "the interface outlived the stop" || ok "the interface is gone after the stop"
got="$(probe selected 9.9.9.2)"
case "$got" in error:111|error:113) ok "selected process after the stop is refused -> $got" ;;
  *) bad "selected process after the stop: wanted a refusal, got $got" ;; esac

# A selected cgroup that only appears later is picked up by run (nft resolves cgroups at load).
tun purge
systemctl --user stop "wefttest$$-keep.service" "$SLICE" >/dev/null 2>&1 || true
for _ in $(seq 50); do [ ! -d "/sys/fs/cgroup/$CG" ] && break; sleep 0.1; done
"${NSC[@]}" python3 -I "$HERE/weft_tunnel.py" --config "$W/cli/t.json" --interval 0.3 run > "$W/run2.log" 2>&1 & RUN=$!; pids+=("$RUN")
sleep 1
tun render | grep -q cgroupv2 && bad "render selects a cgroup that does not exist" || ok "no cgroup rule while the slice is absent"
systemd-run --user --quiet --collect --slice="$SLICE" --unit="wefttest$$-keep2" sleep 600
# run checks every 0.3 s, but one pass (ensure_policy, interface, nft) can take longer on a loaded host: wait up to 6 s.
picked=0
for _ in $(seq 30); do
  sleep 0.2
  in_c nft list table inet weft_t 2>/dev/null | grep -q cgroupv2 && { picked=1; break; }
done
[ "$picked" = 1 ] && ok "run loaded the cgroup once it appeared" || bad "run did not pick up the new cgroup"
expect "selected process in the new slice" 9.9.9.1 "$(probe selected 9.9.9.2)"
kill "$RUN"; wait "$RUN" 2>/dev/null || true

# Purge removes everything and selected traffic is back on the normal route.
tun purge
expect "selected process after purge" 5.5.5.2 "$(probe selected 9.9.9.2)"
in_c ip rule show | grep -q 30777 && bad "purge left an ip rule" || ok "purge removed the rules"
in_c nft list tables | grep -q weft_t && bad "purge left the nft table" || ok "purge removed the nft table"

# weft-peer remove reaches the running server too.
WEFT_WG_DIR="$W/srv" in_s sh "$HERE/weft-peer" remove laptop >/dev/null
in_s wg show wg0 peers | grep -q . && bad "weft-peer remove left the peer on wg0" || ok "weft-peer remove applied live"

# --- on_failure "direct": selected traffic goes the normal way while the server does not answer through the tunnel,
# and enters the tunnel once it does. Live connections keep the route they started on, except tunnel ones once the
# tunnel fails, which are refused so their programs reconnect at once. (The server holds no client here: see above.)
cat > "$W/linesrv.py" <<'PY'
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self):
        for _ in self.rfile:
            self.wfile.write(self.client_address[0].encode() + b"\n")
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", 8081), H).serve_forever()
PY
nsenter --preserve-credentials -t "$I" -U -n python3 -I "$W/linesrv.py" & pids+=("$!")
# long.py TAG: one connection; asks once now and again each time the file TAG.go appears (it removes it), and logs
# each answer (or error:ERRNO) as a line of TAG.out.
cat > "$W/long.py" <<'PY'
import os, socket, sys, time
tag = sys.argv[1]
out = open(tag + ".out", "a", buffering=1)
try:
    s = socket.create_connection(("9.9.9.2", 8081), timeout=3)
    f = s.makefile("rb")
    while True:
        s.sendall(b"?\n")
        line = f.readline()
        if not line:
            raise ConnectionResetError(104, "closed")
        out.write(line.decode())
        while not os.path.exists(tag + ".go"):
            time.sleep(0.05)
        os.unlink(tag + ".go")
except OSError as e:
    out.write(f"error:{e.errno or type(e).__name__}\n")
PY
long() { systemd-run --user --scope --quiet --collect --slice="$SLICE" -- "${NSC[@]}" python3 -I "$W/long.py" "$W/$1" & pids+=("$!"); }
ask() {  # ask TAG: the connection's next answer
  local n; n="$(wc -l < "$W/$1.out" 2>/dev/null || echo 0)"; touch "$W/$1.go"
  for _ in $(seq 40); do [ "$(wc -l < "$W/$1.out")" -gt "$n" ] && break; sleep 0.1; done
  tail -n 1 "$W/$1.out"
}
sed 's/"private_key_file"/"on_failure": "direct", "fail_after": 2, "private_key_file"/' "$W/cli/t.json" > "$W/cli/d.json"
tund() { in_c python3 -I "$HERE/weft_tunnel.py" --config "$W/cli/d.json" "$@"; }
"${NSC[@]}" python3 -I "$HERE/weft_tunnel.py" --config "$W/cli/d.json" --interval 0.3 run > "$W/run3.log" 2>&1 & RUN=$!; pids+=("$RUN")
sleep 1.5
expect "direct: mode while the server does not know the client" direct \
  "$(tund status | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')"
expect "direct: selected process while the server does not answer" 5.5.5.2 "$(probe selected 9.9.9.2)"
long d1; sleep 1
expect "direct: a long connection made before the tunnel answers" 5.5.5.2 "$(tail -n 1 "$W/d1.out")"
WEFT_WG_DIR="$W/srv" in_s sh "$HERE/weft-peer" add laptop "$cpub" 10.77.0.2 >/dev/null
for _ in $(seq 40); do grep -q '"mode": "open"' "$W/run3.log" && break; sleep 0.1; done
grep -q '"mode": "open", "why"' "$W/run3.log" && ok "direct: run entered the tunnel once the server answered" \
  || bad "direct: run did not enter the tunnel after the client was admitted"
expect "direct: selected process with the tunnel healthy" 9.9.9.1 "$(probe selected 9.9.9.2)"
expect "direct: the long connection keeps its route when the tunnel comes up" 5.5.5.2 "$(ask d1)"
tund status >/dev/null && ok "direct: status healthy in the tunnel" || bad "direct: status not healthy in the tunnel"
long d2; sleep 1
expect "direct: a long connection made in the tunnel" 9.9.9.1 "$(tail -n 1 "$W/d2.out")"
WEFT_WG_DIR="$W/srv" in_s sh "$HERE/weft-peer" remove laptop >/dev/null
for _ in $(seq 60); do grep -q '"mode": "direct", "why"' "$W/run3.log" && break; sleep 0.1; done
grep -q '"mode": "direct", "why"' "$W/run3.log" && ok "direct: run left the tunnel once the server stopped answering" \
  || bad "direct: run stayed in the tunnel after the server dropped the client"
expect "direct: selected process after the tunnel failed" 5.5.5.2 "$(probe selected 9.9.9.2)"
expect "direct: the direct long connection survives the failure" 5.5.5.2 "$(ask d1)"
case "$(ask d2)" in error:*) ok "direct: the tunnel long connection is refused after the failure" ;;
  *) bad "direct: the tunnel long connection got $(tail -n 1 "$W/d2.out") after the failure" ;; esac
tund status >/dev/null && bad "direct: status healthy after the failure" || ok "direct: status unhealthy after the failure"
kill -TERM "$RUN"; wait "$RUN" 2>/dev/null || true
grep -q '"stopped": "SIGTERM", "mode": "direct"' "$W/run3.log" && ok "direct: SIGTERM stops run, direct" \
  || bad "direct: stop log: $(tail -n 1 "$W/run3.log")"
expect "direct: selected process after the stop" 5.5.5.2 "$(probe selected 9.9.9.2)"
tund purge
systemctl --user stop "wefttest$$-keep2.service" >/dev/null 2>&1 || true

[ "$fail" -eq 0 ] && echo "all tunnel checks passed" || echo "tunnel checks FAILED"
exit "$fail"
