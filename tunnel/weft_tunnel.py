#!/usr/bin/env python3
"""weft-tunnel: send chosen processes' traffic through a weft egress server, and nothing else.

A WireGuard interface (weft-NAME) carries the traffic; it is never the machine's default route. Instead an nftables
route chain marks the sockets of the configured cgroups (a systemd slice such as egress.slice) and an ip rule sends
marked packets, and packets from sockets bound to the tunnel address, to a routing table of their own whose default
is the tunnel. Everything else on the machine keeps its normal route.

It fails closed: that table ends in an unreachable route, so with the interface down the selected processes get "network
unreachable" rather than leaking out the normal route. `down` removes only the interface; `purge` removes the policy too.

    weft-tunnel --config /etc/weft/tunnel/NAME.json keygen      make the client key, print its public half
    weft-tunnel --config ... up | down | purge | status | run
    weft-tunnel --config ... render                             print the nft ruleset `up` would load
    weft-tunnel --config ... exec -- CMD...                     run CMD (as yourself) in the tunnelled slice

`run` is the service: it brings the tunnel up and every few seconds puts back whatever has gone (the interface, the
rules, the nft table after a firewall reload) and reloads the table when a selected cgroup appears or is recreated
(nft resolves cgroup paths when the table loads). Config keys: see CONFIG_KEYS.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

CGROUP_ROOT = Path("/sys/fs/cgroup")

# Traffic to these never takes the tunnel: loopback, link-local, private and shared space, multicast, broadcast.
LOCAL_V4 = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
            "192.168.0.0/16", "224.0.0.0/4", "255.255.255.255/32"]
LOCAL_V6 = ["::1/128", "fe80::/10", "fc00::/7", "ff00::/8"]

CONFIG_KEYS = {
    "name": "short name, [a-z0-9-]{1,10}; the interface is weft-NAME and the nft table inet weft_NAME",
    "endpoint": "server IPv4:port (the static IP)",
    "server_public_key": "the server's WireGuard public key (weft-peer pubkey)",
    "address": "this client's tunnel address with prefix, e.g. 10.77.0.2/24",
    "cgroups": "cgroup v2 paths under /sys/fs/cgroup whose sockets use the tunnel",
    "bypass": "optional: extra destinations (IPs/CIDRs) that keep the normal route even from selected cgroups",
    "private_key_file": "optional: default /etc/weft/tunnel/NAME.key",
    "table": "optional routing table id, default 30777",
    "fwmark": "optional single-bit mark for selected traffic, default 0x20000000",
    "wg_fwmark": "optional single-bit mark WireGuard puts on its own packets, default 0x10000000",
    "rule_priority": "optional ip rule priority (and +1), default 5270",
    "mtu": "optional, default 1420",
    "keepalive": "optional seconds, default 25",
    "exec_slice": "optional slice `exec` runs commands in, default the last part of the first cgroup",
    "on_failure": "optional: 'closed' (default) refuses selected traffic while the tunnel is down or unhealthy; "
                  "'direct' sends new connections the normal way meanwhile (run probes the server to decide)",
    "server_address": "optional: the server's tunnel address `run` probes, default the first host of the network",
    "fail_after": "optional: failed probes in a row before on_failure 'direct' leaves the tunnel, default 3",
}
MODES = ("open", "closed", "direct")
REQUIRED = ("name", "endpoint", "server_public_key", "address", "cgroups")
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,9}$")
# Paths go into nft as quoted strings: keep them to what systemd unit and slice names use.
CGROUP_RE = re.compile(r"^[A-Za-z0-9_.@:\\-]+(/[A-Za-z0-9_.@:\\-]+)*$")


class ConfigError(ValueError):
    pass


def _single_bit(value, key: str) -> int:
    mark = int(value, 0) if isinstance(value, str) else int(value)
    if mark <= 0 or mark >= 1 << 32 or mark & (mark - 1):
        raise ConfigError(f"{key} must be a single bit below 2**32, got {value!r}")
    return mark


def load_config(path: Path) -> dict:
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError(f"{path} must hold a JSON object")
    unknown = sorted(set(raw) - set(CONFIG_KEYS))
    if unknown:
        raise ConfigError(f"unknown config keys {unknown}; known: {sorted(CONFIG_KEYS)}")
    missing = [k for k in REQUIRED if not raw.get(k)]
    if missing:
        raise ConfigError(f"missing config keys {missing}")

    name = raw["name"]
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ConfigError(f"name {name!r}: use 1-10 lowercase letters, digits and dashes")

    host, sep, port = str(raw["endpoint"]).rpartition(":")
    try:
        endpoint_ip = ipaddress.IPv4Address(host)
        port_n = int(port)
    except ValueError as exc:
        raise ConfigError(f"endpoint {raw['endpoint']!r} must be IPv4:port") from exc
    if not sep or not 0 < port_n < 65536 or not endpoint_ip.is_global:
        raise ConfigError(f"endpoint {raw['endpoint']!r} must be a public IPv4:port")

    if not KEY_RE.match(str(raw["server_public_key"])):
        raise ConfigError("server_public_key is not a WireGuard public key")

    try:
        iface_addr = ipaddress.IPv4Interface(raw["address"])
    except ValueError as exc:
        raise ConfigError(f"address {raw['address']!r} must be IPv4 with a prefix, e.g. 10.77.0.2/24") from exc
    if iface_addr.network.prefixlen == 32 or iface_addr.ip in (iface_addr.network.network_address,
                                                               iface_addr.network.broadcast_address):
        raise ConfigError(f"address {raw['address']!r} is not a host address in a subnet")

    cgroups = raw["cgroups"]
    if not isinstance(cgroups, list) or not cgroups:
        raise ConfigError("cgroups must be a non-empty list of paths")
    clean = []
    for cg in cgroups:
        cg = str(cg).strip("/")
        if not CGROUP_RE.match(cg) or any(part in (".", "..") for part in cg.split("/")):
            raise ConfigError(f"cgroup path {cg!r} is not a plain cgroup path")
        clean.append(cg)

    bypass4, bypass6 = [], []
    for item in raw.get("bypass", []):
        try:
            net = ipaddress.ip_network(str(item), strict=False)
        except ValueError as exc:
            raise ConfigError(f"bypass entry {item!r} is not an IP or CIDR") from exc
        (bypass4 if net.version == 4 else bypass6).append(str(net))

    fwmark = _single_bit(raw.get("fwmark", 0x20000000), "fwmark")
    wg_fwmark = _single_bit(raw.get("wg_fwmark", 0x10000000), "wg_fwmark")
    if fwmark == wg_fwmark:
        raise ConfigError("fwmark and wg_fwmark must be different bits")
    table = int(raw.get("table", 30777))
    if not 0 < table < 1 << 32 or table in (253, 254, 255):
        raise ConfigError(f"table {table} is reserved or out of range")
    priority = int(raw.get("rule_priority", 5270))
    if not 0 < priority < 32765:
        raise ConfigError(f"rule_priority {priority} must sit before the main table's 32766")
    mtu = int(raw.get("mtu", 1420))
    if not 1280 <= mtu <= 1500:
        raise ConfigError(f"mtu {mtu} must be 1280..1500")

    keepalive = int(raw.get("keepalive", 25))
    if not 0 <= keepalive <= 600:
        raise ConfigError(f"keepalive {keepalive} must be 0..600 seconds")
    exec_slice = raw.get("exec_slice") or clean[0].rsplit("/", 1)[-1]
    if not re.match(r"^[A-Za-z0-9_.:-]+\.slice$", str(exec_slice)):
        raise ConfigError(f"exec_slice {exec_slice!r} must be a systemd slice name (NAME.slice)")

    on_failure = raw.get("on_failure", "closed")
    if on_failure not in ("closed", "direct"):
        raise ConfigError(f"on_failure {on_failure!r} must be 'closed' or 'direct'")
    try:
        server_address = ipaddress.IPv4Address(raw.get("server_address") or next(iface_addr.network.hosts()))
    except ValueError as exc:
        raise ConfigError(f"server_address {raw.get('server_address')!r} is not an IPv4 address") from exc
    if server_address not in iface_addr.network or server_address == iface_addr.ip:
        raise ConfigError(f"server_address {server_address} must be another address in {iface_addr.network}")
    fail_after = raw.get("fail_after", 3)
    if type(fail_after) is not int or not 1 <= fail_after <= 100:
        raise ConfigError(f"fail_after {fail_after} must be 1..100")

    return {
        "name": name,
        "iface": f"weft-{name}",
        "table_name": "weft_" + name.replace("-", "_"),
        "endpoint": f"{endpoint_ip}:{port_n}",
        "endpoint_ip": str(endpoint_ip),
        "server_public_key": raw["server_public_key"],
        "address": str(iface_addr),
        "address_ip": str(iface_addr.ip),
        "cgroups": clean,
        "bypass4": bypass4,
        "bypass6": bypass6,
        "private_key_file": raw.get("private_key_file", f"/etc/weft/tunnel/{name}.key"),
        "table": table,
        "fwmark": fwmark,
        "wg_fwmark": wg_fwmark,
        "priority": priority,
        "mtu": mtu,
        "keepalive": keepalive,
        "exec_slice": exec_slice,
        "on_failure": on_failure,
        "server_address": str(server_address),
        "fail_after": fail_after,
    }


def cgroup_ids(cfg: dict, root: Path = CGROUP_ROOT) -> dict:
    """The inode (nft's cgroup id) of each selected cgroup, or None while it does not exist."""
    ids = {}
    for cg in cfg["cgroups"]:
        try:
            ids[cg] = os.stat(root / cg).st_ino
        except FileNotFoundError:
            ids[cg] = None
    return ids


def render_nft(cfg: dict, present: list[str], mode: str = "open") -> str:
    """The whole table, replaced atomically (the add/delete/define idiom).

    open: a route chain marks selected traffic so the policy rules send it into the tunnel.
    closed (after `down`, on_failure 'closed'): a filter chain refuses it at once (TCP reset, ICMP otherwise), so
      callers fail fast instead of waiting on retransmits into the unreachable route, which stays as the floor for
      any moment between the two.
    direct (tunnel down or unhealthy, on_failure 'direct'): selected traffic takes the normal route; connections
      already in the tunnel are refused so their programs reconnect the normal way at once.
    In every mode only new connections are steered: one that exists keeps the route it started on, so bringing the
    tunnel up or down never moves a live connection to another source address mid-flow.
    """
    if mode not in MODES:
        raise ValueError(f"mode {mode!r}")
    closed = mode != "open"
    mark, wgmark, iface, t = cfg["fwmark"], cfg["wg_fwmark"], cfg["iface"], cfg["table_name"]
    v4 = ", ".join(LOCAL_V4 + cfg["bypass4"])
    v6 = ", ".join(LOCAL_V6 + cfg["bypass6"])
    select = []
    if mode == "direct":
        select.append("    # tunnel down or unhealthy: selected traffic takes the normal route (on_failure direct)")
        present = []
    elif not present:
        select.append("    # no selected cgroup exists yet; weft-tunnel run reloads this table when one appears")
    for cg in present:
        level = len(cg.split("/"))
        select.append(f'    socket cgroupv2 level {level} "{cg}" jump {"refuse" if closed else "tunnel"}')
    return "\n".join([
        f"table inet {t}",
        f"delete table inet {t}",
        f"table inet {t} {{",
        f'  comment "weft-tunnel mode={mode}"',
        "  set bypass4 { type ipv4_addr; flags interval; auto-merge; elements = { " + v4 + " } }",
        "  set bypass6 { type ipv6_addr; flags interval; auto-merge; elements = { " + v6 + " } }",
        "  chain output {",
        "    type filter hook output priority filter; policy accept;" if closed else
        "    type route hook output priority mangle; policy accept;",
        f"    meta mark and {wgmark:#x} == {wgmark:#x} return",
        "    ip daddr @bypass4 return",
        "    ip6 daddr @bypass6 return",
        # A connection that started in the tunnel stays there, including packets no longer tied to the socket.
        f"    ct mark and {mark:#x} == {mark:#x} jump refuse" if closed else
        f"    ct mark and {mark:#x} == {mark:#x} meta mark set meta mark or {mark:#x} return",
        "    ct state != new return",
        *select,
        "  }",
        *(["  chain refuse {",
           "    meta l4proto tcp reject with tcp reset",
           "    reject with icmpx admin-prohibited",
           "  }"] if closed else []),
        "  chain tunnel {",
        f"    meta mark set meta mark or {mark:#x}",
        f"    ct mark set ct mark or {mark:#x}",
        "  }",
        "  chain postrouting {",
        "    type nat hook postrouting priority srcnat; policy accept;",
        f'    oifname "{iface}" ip saddr != {cfg["address_ip"]} masquerade',
        "  }",
        "  chain clamp {",
        "    type filter hook postrouting priority mangle; policy accept;",
        f'    oifname "{iface}" tcp flags syn tcp option maxseg size set rt mtu',
        "  }",
        "}",
        "",
    ])


def tool(name: str) -> str:
    found = shutil.which(name) or next((p for p in (f"/usr/sbin/{name}", f"/usr/bin/{name}", f"/sbin/{name}")
                                         if os.access(p, os.X_OK)), None)
    if not found:
        hint = " (apt-get install wireguard-tools)" if name == "wg" else ""
        raise SystemExit(f"weft-tunnel: {name} not found{hint}")
    return found


def sh(*argv: str, check: bool = True, stdin: str | None = None) -> subprocess.CompletedProcess:
    cmd = [tool(argv[0]), *argv[1:]]
    proc = subprocess.run(cmd, input=stdin, text=True, capture_output=True)
    if check and proc.returncode:
        raise SystemExit(f"weft-tunnel: {' '.join(argv)} failed: {(proc.stderr or proc.stdout).strip()}")
    return proc


def have_ipv6() -> bool:
    return Path("/proc/sys/net/ipv6").exists()


def write_sysctl(path: str, value: str) -> None:
    try:
        Path(path).write_text(value)
    except OSError as exc:
        print(f"weft-tunnel: could not set {path}={value}: {exc}", file=sys.stderr)


def iface_exists(cfg: dict) -> bool:
    # Ask the kernel, not /sys/class/net: sysfs shows the namespace it was mounted in, not necessarily ours.
    return sh("ip", "-o", "link", "show", "dev", cfg["iface"], check=False).returncode == 0


def rules_text(family: str) -> str:
    return sh("ip", family, "rule", "show").stdout


def rule_lines(cfg: dict) -> list[tuple[str, list[str], str]]:
    """(family, `ip rule add` args, the text `ip rule show` prints for it)."""
    p, t, m = cfg["priority"], cfg["table"], cfg["fwmark"]
    rules = [("-4", ["priority", str(p), "fwmark", f"{m:#x}/{m:#x}", "lookup", str(t)],
              f"{p}:\tfrom all fwmark {m:#x}/{m:#x} lookup {t}"),
             ("-4", ["priority", str(p + 1), "from", cfg["address_ip"], "lookup", str(t)],
              f"{p + 1}:\tfrom {cfg['address_ip']} lookup {t}")]
    if have_ipv6():
        rules.append(("-6", ["priority", str(p), "fwmark", f"{m:#x}/{m:#x}", "lookup", str(t)],
                      f"{p}:\tfrom all fwmark {m:#x}/{m:#x} lookup {t}"))
    return rules


def ensure_policy(cfg: dict) -> list[str]:
    """Routing table, rules and nft table. Returns what had to be (re)made."""
    made = []
    t = str(cfg["table"])
    # The fail-closed floor: with the tunnel's own route gone, selected traffic hits this rather than the main table.
    routes = sh("ip", "-4", "route", "show", "table", t, check=False).stdout
    if "unreachable default" not in routes:
        sh("ip", "-4", "route", "replace", "unreachable", "default", "metric", "4294967295", "table", t)
        made.append("v4 unreachable floor")
    if have_ipv6():
        routes6 = sh("ip", "-6", "route", "show", "table", t, check=False).stdout
        if "unreachable default" not in routes6:
            sh("ip", "-6", "route", "replace", "unreachable", "default", "metric", "4294967295", "table", t)
            made.append("v6 unreachable floor")
    shown = {"-4": rules_text("-4"), "-6": rules_text("-6") if have_ipv6() else ""}
    for family, args, text in rule_lines(cfg):
        if text not in shown[family]:
            sh("ip", family, "rule", "add", *args)
            made.append(f"rule {family} {' '.join(args)}")
    return made


def table_mode(cfg: dict) -> str | None:
    """The mode of the loaded table, or None when there is none."""
    table = sh("nft", "list", "table", "inet", cfg["table_name"], check=False)
    if table.returncode:
        return None
    found = re.search(r'comment "weft-tunnel mode=(\w+)"', table.stdout)
    return found.group(1) if found else "unknown"


def ensure_nft(cfg: dict, ids: dict, force: bool = False, mode: str = "open") -> bool:
    if not force and table_mode(cfg) == mode:
        return False
    present = [cg for cg, ino in ids.items() if ino is not None]
    sh("nft", "-f", "-", stdin=render_nft(cfg, present, mode=mode))
    return True


def down_mode(cfg: dict) -> str:
    return "direct" if cfg["on_failure"] == "direct" else "closed"


def _icmp_checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    total = (total >> 16) + (total & 0xFFFF)
    total += total >> 16
    return ~total & 0xFFFF


def probe(cfg: dict, timeout: float = 2.0) -> bool:
    """One ICMP echo to the server through the tunnel (bound to the tunnel address, so the policy rule routes it in).
    WireGuard queues it through a handshake, so a fresh interface answers too once the server is there.

    An unprivileged ping socket is used where net.ipv4.ping_group_range allows it, else a raw socket (CAP_NET_RAW)."""
    if not iface_exists(cfg):
        return False
    body = struct.pack("!d", time.time())
    ident = os.getpid() & 0xFFFF
    for kind in (socket.SOCK_DGRAM, socket.SOCK_RAW):
        try:
            s = socket.socket(socket.AF_INET, kind, socket.IPPROTO_ICMP)
        except PermissionError:
            continue
        except OSError:
            return False
        with s:
            try:
                s.settimeout(timeout)
                s.bind((cfg["address_ip"], 0))
                packet = struct.pack("!BBHHH", 8, 0, 0, ident, 1) + body
                if kind == socket.SOCK_RAW:  # the kernel fills in the checksum (and the id) only for ping sockets
                    packet = packet[:2] + struct.pack("!H", _icmp_checksum(packet)) + packet[4:]
                s.sendto(packet, (cfg["server_address"], 0))
                deadline = time.monotonic() + timeout
                while (left := deadline - time.monotonic()) > 0:
                    s.settimeout(left)
                    data, addr = s.recvfrom(2048)
                    if kind == socket.SOCK_RAW:  # a raw socket hands over the IP header too
                        data = data[(data[0] & 0x0F) * 4:]
                    if addr[0] == cfg["server_address"] and data[:1] == b"\x00" and data[8:16] == body:
                        return True
            except OSError:
                return False
        return False
    return False


def ensure_iface(cfg: dict) -> bool:
    key = Path(cfg["private_key_file"])
    if not key.is_file():
        raise SystemExit(f"weft-tunnel: no private key at {key}; run keygen first")
    if key.stat().st_mode & 0o077:
        raise SystemExit(f"weft-tunnel: {key} is readable by others; chmod 600 it")
    iface, made = cfg["iface"], False
    if not iface_exists(cfg):
        sh("ip", "link", "add", iface, "type", "wireguard")
        made = True
    sh("wg", "set", iface, "private-key", str(key), "fwmark", f"{cfg['wg_fwmark']:#x}",
       "peer", cfg["server_public_key"], "endpoint", cfg["endpoint"], "allowed-ips", "0.0.0.0/0",
       "persistent-keepalive", str(cfg["keepalive"]))
    # Only one peer: drop any other a hand edit left behind.
    for peer in sh("wg", "show", iface, "peers").stdout.split():
        if peer != cfg["server_public_key"]:
            sh("wg", "set", iface, "peer", peer, "remove")
    sh("ip", "-4", "address", "replace", cfg["address"], "dev", iface)
    sh("ip", "link", "set", iface, "mtu", str(cfg["mtu"]), "up")
    if have_ipv6():
        write_sysctl(f"/proc/sys/net/ipv6/conf/{iface}/disable_ipv6", "1")
    # Loose reverse-path checking: replies arrive on the tunnel from addresses the main table routes elsewhere.
    write_sysctl(f"/proc/sys/net/ipv4/conf/{iface}/rp_filter", "2")
    routes = sh("ip", "-4", "route", "show", "table", str(cfg["table"])).stdout
    if not re.search(rf"^default dev {re.escape(iface)}\b", routes, re.M):
        sh("ip", "-4", "route", "replace", "default", "dev", iface, "table", str(cfg["table"]))
        made = True
    return made


def cmd_up(cfg: dict, mode: str = "open") -> dict:
    ids = cgroup_ids(cfg)
    made = ensure_policy(cfg)  # policy first: nothing selected can slip out while the interface comes up
    if ensure_nft(cfg, ids, force=True, mode=mode):
        made.append("nft table")
    if ensure_iface(cfg):
        made.append("interface")
    return {"made": made, "cgroups": ids, "mode": mode}


def cmd_down(cfg: dict) -> None:
    """Close (refuse selected traffic; with on_failure 'direct', send it the normal way), then remove the interface.
    The policy stays, so with on_failure 'closed' nothing selected leaks."""
    ensure_policy(cfg)
    ensure_nft(cfg, cgroup_ids(cfg), force=True, mode=down_mode(cfg))
    if iface_exists(cfg):
        sh("ip", "link", "del", cfg["iface"])


def cmd_purge(cfg: dict) -> None:
    cmd_down(cfg)
    sh("nft", "delete", "table", "inet", cfg["table_name"], check=False)
    for family, args, _ in rule_lines(cfg):
        while sh("ip", family, "rule", "del", *args, check=False).returncode == 0:
            pass
    for family in ("-4", "-6") if have_ipv6() else ("-4",):
        sh("ip", family, "route", "flush", "table", str(cfg["table"]), check=False)


def cmd_status(cfg: dict) -> dict:
    out = {"interface": cfg["iface"], "up": iface_exists(cfg), "cgroups": cgroup_ids(cfg)}
    if out["up"]:
        dump = sh("wg", "show", cfg["iface"], "dump", check=False).stdout.splitlines()
        if len(dump) > 1:
            f = dump[1].split("\t")
            out.update(endpoint=f[2], latest_handshake=int(f[4]), rx_bytes=int(f[5]), tx_bytes=int(f[6]))
            out["handshake_age_s"] = int(time.time()) - out["latest_handshake"] if out["latest_handshake"] else None
    out["mode"] = table_mode(cfg)
    out["nft_table"] = out["mode"] is not None
    out["on_failure"] = cfg["on_failure"]
    out["probe"] = probe(cfg) if out["up"] else False
    shown = {"-4": rules_text("-4"), "-6": rules_text("-6") if have_ipv6() else ""}
    out["rules"] = all(text in shown[f] for f, _, text in rule_lines(cfg))
    routes = sh("ip", "-4", "route", "show", "table", str(cfg["table"]), check=False).stdout
    out["fail_closed"] = "unreachable default" in routes
    return out


class _Stop(Exception):
    pass


def _stop(signum, _frame):
    raise _Stop(signal.Signals(signum).name)


def cmd_run(cfg: dict, interval: float) -> None:
    """The service loop. SIGTERM/SIGINT close the tunnel (as `down`) here, so a stop can never race a restore."""
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    # on_failure 'direct' starts direct and enters the tunnel once the server answers through it; it leaves after
    # fail_after failed probes in a row. 'closed' is always open while running (the floor and `down` do the closing).
    watch = cfg["on_failure"] == "direct"
    mode = "direct" if watch else "open"
    fails = 0
    try:
        print(json.dumps(cmd_up(cfg, mode)), flush=True)
        ids = cgroup_ids(cfg)
        while True:
            time.sleep(interval)
            made = ensure_policy(cfg)
            if ensure_iface(cfg):
                made.append("interface")
            switched = None
            if watch:
                healthy = probe(cfg, timeout=min(2.0, max(interval, 0.5)))
                fails = 0 if healthy else fails + 1
                if mode == "direct" and healthy:
                    mode, switched = "open", "the server answers through the tunnel"
                elif mode == "open" and fails >= cfg["fail_after"]:
                    mode, switched = "direct", f"{fails} probes in a row failed"
            now = cgroup_ids(cfg)
            if ensure_nft(cfg, now, force=now != ids or switched is not None, mode=mode) and not switched:
                made.append("nft table")
            ids = now
            if switched:
                print(json.dumps({"mode": mode, "why": switched}), flush=True)
            if made:
                print(json.dumps({"restored": made, "cgroups": ids, "mode": mode}), flush=True)
    except _Stop as exc:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        cmd_down(cfg)
        print(json.dumps({"stopped": str(exc), "mode": down_mode(cfg)}), flush=True)


def cmd_keygen(cfg: dict) -> str:
    key = Path(cfg["private_key_file"])
    if not key.exists():
        key.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        old = os.umask(0o077)
        try:
            key.write_text(sh("wg", "genkey").stdout)
        finally:
            os.umask(old)
    return sh("wg", "pubkey", stdin=key.read_text()).stdout.strip()


def cmd_exec(cfg: dict, argv: list[str]) -> int:
    if not argv:
        raise SystemExit("weft-tunnel exec: give a command after --")
    if os.geteuid() == 0:
        raise SystemExit("weft-tunnel exec: run it as the user whose slice it is, not root")
    cmd = [tool("systemd-run"), "--user", "--scope", "--quiet", "--collect", f"--slice={cfg['exec_slice']}", "--",
           *argv]
    os.execv(cmd[0], cmd)
    return 127


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="weft-tunnel", description=__doc__.split("\n\n")[0])
    ap.add_argument("--config", required=True, type=Path)
    ap.add_argument("--interval", type=float, default=2.0, help="run: seconds between checks")
    ap.add_argument("--mode", choices=MODES, default="open", help="render: which ruleset (down loads closed or direct)")
    ap.add_argument("command", choices=["keygen", "up", "down", "purge", "status", "run", "render", "check", "exec"])
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(f"weft-tunnel: {exc}", file=sys.stderr)
        return 2
    if args.command == "check":
        print(json.dumps({k: v for k, v in cfg.items() if k != "private_key_file"}, indent=2))
        return 0
    if args.command == "render":
        present = [cg for cg, ino in cgroup_ids(cfg).items() if ino is not None]
        sys.stdout.write(render_nft(cfg, present, mode=args.mode))
        return 0
    if args.command == "exec":
        rest = args.rest[1:] if args.rest[:1] == ["--"] else args.rest
        return cmd_exec(cfg, rest)
    if os.geteuid() != 0:
        print(f"weft-tunnel: {args.command} needs root", file=sys.stderr)
        return 1
    if args.command == "keygen":
        print(cmd_keygen(cfg))
    elif args.command == "up":
        print(json.dumps(cmd_up(cfg)))
    elif args.command == "down":
        cmd_down(cfg)
    elif args.command == "purge":
        cmd_purge(cfg)
    elif args.command == "status":
        st = cmd_status(cfg)
        print(json.dumps(st, indent=2))
        return 0 if st["up"] and st["mode"] == "open" and st["probe"] and st["rules"] and st["fail_closed"] else 1
    elif args.command == "run":
        cmd_run(cfg, args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
