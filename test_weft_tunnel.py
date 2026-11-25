"""Offline tests for weft's static IP and tunnel egress: the client config and ruleset (tunnel/weft_tunnel.py), the
server's peer manager (tunnel/weft-peer), weft.sh's destroy guard, rebuild and tunnel commands, and the rootless
three-namespace end-to-end test (tunnel/test_tunnel_netns.sh), which runs when WireGuard tools are at hand.

Every fixture uses invented names and documentation addresses; no cloud call, no real .env, state or key."""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TUNNEL = HERE / "tunnel"

spec = importlib.util.spec_from_file_location("weft_tunnel", TUNNEL / "weft_tunnel.py")
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)


def wg_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


def write_exe(path: Path, text: str) -> Path:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


GOOD = {
    "name": "office",
    "endpoint": "203.0.114.7:51820",  # 203.0.114/24 is public (203.0.113/24 is documentation and not global)
    "server_public_key": wg_key(),
    "address": "10.77.0.2/24",
    "cgroups": ["user.slice/user-1000.slice/user@1000.service/app.slice"],
    "bypass": ["198.51.100.10", "2001:db8::/32"],
}


def load(tmp_path, **changes):
    raw = {**GOOD, **changes}
    for k in [k for k, v in raw.items() if v is None]:
        del raw[k]
    p = tmp_path / "c.json"
    p.write_text(json.dumps(raw))
    return wt.load_config(p)


# --- client config -----------------------------------------------------------------------------------------------

def test_a_good_config_loads_with_its_defaults(tmp_path):
    cfg = load(tmp_path, cgroups=["/user.slice/user-1000.slice/user@1000.service/app.slice/"])
    assert cfg["iface"] == "weft-office" and cfg["table_name"] == "weft_office"
    assert cfg["address_ip"] == "10.77.0.2" and cfg["endpoint_ip"] == "203.0.114.7"
    assert cfg["cgroups"] == ["user.slice/user-1000.slice/user@1000.service/app.slice"]  # slashes trimmed
    assert cfg["bypass4"] == ["198.51.100.10/32"] and cfg["bypass6"] == ["2001:db8::/32"]
    assert (cfg["table"], cfg["fwmark"], cfg["wg_fwmark"], cfg["priority"]) == (30777, 0x20000000, 0x10000000, 5270)
    assert cfg["private_key_file"] == "/etc/weft/tunnel/office.key"
    assert cfg["exec_slice"] == "app.slice"
    assert (cfg["on_failure"], cfg["server_address"], cfg["fail_after"]) == ("closed", "10.77.0.1", 3)


def test_on_failure_direct_and_a_named_server_address_load(tmp_path):
    cfg = load(tmp_path, on_failure="direct", server_address="10.77.0.9", fail_after=5)
    assert (cfg["on_failure"], cfg["server_address"], cfg["fail_after"]) == ("direct", "10.77.0.9", 5)


@pytest.mark.parametrize("changes, words", [
    ({"name": "Office"}, "name"),
    ({"name": "much-too-long"}, "name"),
    ({"endpoint": "10.0.0.5:51820"}, "public"),
    ({"endpoint": "203.0.114.7"}, "endpoint"),
    ({"endpoint": "203.0.114.7:0"}, "public"),
    ({"endpoint": "egress.example.com:51820"}, "endpoint"),
    ({"server_public_key": "not-a-key"}, "server_public_key"),
    ({"address": "10.77.0.2"}, "host address"),
    ({"address": "10.77.0.0/24"}, "host address"),
    ({"address": "fd00::2/64"}, "IPv4"),
    ({"cgroups": []}, "missing"),
    ({"cgroups": "app.slice"}, "non-empty list"),
    ({"cgroups": ["user.slice/../system.slice"]}, "plain cgroup"),
    ({"cgroups": ['app.slice" accept; #']}, "plain cgroup"),
    ({"bypass": ["example.com"]}, "bypass"),
    ({"fwmark": 3}, "fwmark"),
    ({"fwmark": 0x10000000}, "different bits"),
    ({"table": 254}, "reserved"),
    ({"rule_priority": 32766}, "main table"),
    ({"mtu": 9000}, "mtu"),
    ({"keepalive": -1}, "keepalive"),
    ({"exec_slice": "app; rm -rf /"}, "slice"),
    ({"on_failure": "open"}, "on_failure"),
    ({"server_address": "10.78.0.1"}, "server_address"),
    ({"server_address": "10.77.0.2"}, "server_address"),
    ({"server_address": "egress"}, "server_address"),
    ({"fail_after": 0}, "fail_after"),
    ({"fail_after": "3"}, "fail_after"),
    ({"surprise": 1}, "unknown"),
    ({"address": None}, "missing"),
])
def test_a_bad_config_is_refused_with_the_reason(tmp_path, changes, words):
    with pytest.raises(wt.ConfigError, match=words):
        load(tmp_path, **changes)


def test_the_open_ruleset_marks_only_selected_cgroups_and_spares_local_and_bypass(tmp_path):
    cfg = load(tmp_path)
    cg = cfg["cgroups"][0]
    nft = wt.render_nft(cfg, [cg])
    assert f'socket cgroupv2 level 4 "{cg}" jump tunnel' in nft
    assert "type route hook output" in nft
    for net in ("127.0.0.0/8", "10.0.0.0/8", "192.168.0.0/16", "198.51.100.10/32", "2001:db8::/32"):
        assert net in nft
    assert "0x10000000" in nft  # WireGuard's own packets are never re-marked into the tunnel
    assert 'oifname "weft-office"' in nft and "masquerade" in nft
    assert "jump refuse" not in nft


def test_the_closed_ruleset_refuses_selected_cgroups_and_the_tunnel_address(tmp_path):
    cfg = load(tmp_path)
    cg = cfg["cgroups"][0]
    nft = wt.render_nft(cfg, [cg], mode="closed")
    assert f'socket cgroupv2 level 4 "{cg}" jump refuse' in nft
    assert "reject with tcp reset" in nft
    assert "jump tunnel" not in nft


def test_every_ruleset_steers_only_new_connections(tmp_path):
    cfg = load(tmp_path)
    for mode in wt.MODES:
        nft = wt.render_nft(cfg, cfg["cgroups"], mode=mode)
        restore, new_only = nft.index("ct mark and"), nft.index("ct state != new return")
        assert restore < new_only  # a tunnel connection keeps its mark; any other existing one keeps its route
        assert f'comment "weft-tunnel mode={mode}"' in nft
    with pytest.raises(ValueError):
        wt.render_nft(cfg, cfg["cgroups"], mode="sideways")


def test_the_direct_ruleset_sends_selected_cgroups_the_normal_way_and_refuses_tunnel_flows(tmp_path):
    cfg = load(tmp_path, on_failure="direct")
    nft = wt.render_nft(cfg, cfg["cgroups"], mode="direct")
    assert "socket cgroupv2" not in nft and "jump tunnel" not in nft
    assert "ct mark and 0x20000000 == 0x20000000 jump refuse" in nft
    assert wt.down_mode(cfg) == "direct" and wt.down_mode(load(tmp_path)) == "closed"


def test_a_missing_cgroup_renders_no_selector_until_it_appears(tmp_path):
    cfg = load(tmp_path)
    nft = wt.render_nft(cfg, [])
    assert "socket cgroupv2" not in nft and "no selected cgroup exists yet" in nft
    assert wt.cgroup_ids(cfg, root=tmp_path) == {cfg["cgroups"][0]: None}
    (tmp_path / cfg["cgroups"][0]).mkdir(parents=True)
    assert wt.cgroup_ids(cfg, root=tmp_path)[cfg["cgroups"][0]] == (tmp_path / cfg["cgroups"][0]).stat().st_ino


def test_check_runs_unprivileged_and_never_prints_the_key_path(tmp_path):
    p = tmp_path / "c.json"
    p.write_text(json.dumps(GOOD))
    out = subprocess.run(["python3", "-I", str(TUNNEL / "weft_tunnel.py"), "--config", str(p), "check"],
                         capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout)["iface"] == "weft-office" and "private_key_file" not in out.stdout
    p.write_text(json.dumps({**GOOD, "endpoint": "192.168.1.1:51820"}))
    bad = subprocess.run(["python3", "-I", str(TUNNEL / "weft_tunnel.py"), "--config", str(p), "check"],
                         capture_output=True, text=True, timeout=30)
    assert bad.returncode == 2 and "public" in bad.stderr


# --- server peer manager -----------------------------------------------------------------------------------------

@pytest.fixture
def peer(tmp_path):
    wgdir = tmp_path / "wg"
    wgdir.mkdir()
    (wgdir / "wg0.conf").write_text("[Interface]\nAddress = 10.77.0.1/24\nListenPort = 51820\n"
                                    "PostUp = wg set %i private-key /etc/wireguard/server.key\n")
    (wgdir / "server.pub").write_text("SERVERPUB\n")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    write_exe(bindir / "id", '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n')
    write_exe(bindir / "ip", '#!/bin/sh\n[ -n "$FAKE_WG0_UP" ]\n')
    write_exe(bindir / "wg", '#!/bin/sh\necho "wg $*" >> "$FAKE_WG_LOG"\n')
    log = tmp_path / "wg.log"

    def run(*args, up=False):
        env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}", "WEFT_WG_DIR": str(wgdir),
               "FAKE_WG_LOG": str(log)}
        if up:
            env["FAKE_WG0_UP"] = "1"
        p = subprocess.run(["sh", str(TUNNEL / "weft-peer"), *args], env=env, capture_output=True, text=True,
                           timeout=30)
        calls = log.read_text().splitlines() if log.exists() else []
        log.unlink(missing_ok=True)
        return p.returncode, p.stdout + p.stderr, calls

    run.conf = wgdir / "wg0.conf"
    return run


def test_peers_are_added_listed_replaced_and_removed(peer):
    a, b, a2 = wg_key(), wg_key(), wg_key()
    assert peer("pubkey")[1].strip() == "SERVERPUB"
    assert peer("add", "laptop", a, "10.77.0.2")[0] == 0
    assert peer("add", "spare", b, "10.77.0.3")[0] == 0
    assert peer("list")[1].split("\n")[:2] == [f"laptop {a} 10.77.0.2", f"spare {b} 10.77.0.3"]
    rc, _, calls = peer("add", "laptop", a2, "10.77.0.4", up=True)
    assert rc == 0
    assert calls == [f"wg set wg0 peer {a} remove", f"wg set wg0 peer {a2} allowed-ips 10.77.0.4/32"]
    assert f"laptop {a2} 10.77.0.4" in peer("list")[1] and a not in run_conf(peer)
    rc, _, calls = peer("remove", "spare", up=True)
    assert rc == 0 and calls == [f"wg set wg0 peer {b} remove"]
    assert peer("list")[1].strip() == f"laptop {a2} 10.77.0.4"
    conf = run_conf(peer)
    assert "PostUp = wg set %i private-key /etc/wireguard/server.key" in conf  # the server key line survives
    assert oct(peer.conf.stat().st_mode & 0o777) == "0o600"


def run_conf(peer) -> str:
    return peer.conf.read_text()


@pytest.mark.parametrize("args, words", [
    (("add", "Bad_Name", None, "10.77.0.2"), "name"),
    (("add", "laptop", "nokey", "10.77.0.2"), "public key"),
    (("add", "laptop", None, "10.78.0.2"), "outside"),
    (("add", "laptop", None, "10.77.0.1"), ".2 to .254"),
    (("add", "laptop", None, "10.77.0.255"), ".2 to .254"),
    (("add", "laptop", None, "10.77.0.02"), "not an IPv4"),
    (("add", "laptop", None, "10.77.0.2/32"), "not an IPv4"),
    (("remove", "nobody"), "no client"),
    (("add", "laptop"), "usage"),
])
def test_bad_peer_requests_are_refused_and_leave_the_conf_alone(peer, args, words):
    before = run_conf(peer)
    args = tuple(wg_key() if a is None else a for a in args)
    rc, out, calls = peer(*args, up=True)
    assert rc == 1 and words in out and calls == []
    assert run_conf(peer) == before


def test_an_address_or_key_held_by_another_client_is_refused(peer):
    a = wg_key()
    assert peer("add", "laptop", a, "10.77.0.2")[0] == 0
    rc, out, _ = peer("add", "other", wg_key(), "10.77.0.2")
    assert rc == 1 and "already belongs to client 'laptop'" in out
    rc, out, _ = peer("add", "other", a, "10.77.0.9")
    assert rc == 1 and "key already belongs to client 'laptop'" in out


def test_weft_peer_refuses_non_root(tmp_path):
    p = subprocess.run(["sh", str(TUNNEL / "weft-peer"), "list"], capture_output=True, text=True, timeout=30,
                       env={**os.environ, "WEFT_WG_DIR": str(tmp_path)})
    if os.geteuid() == 0:
        pytest.skip("running as root")
    assert p.returncode == 1 and "run as root" in p.stderr


# --- weft.sh: destroy guard, rebuild, tunnel -----------------------------------------------------------------------

FAKE_TF = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "workspace show") echo "${TF_WORKSPACE:-default}"; exit 0 ;;
  "state list") cat "$FAKE_STATE"; exit 0 ;;
  "output -raw")
    case "$3" in server_ip|static_ip) printf '203.0.114.7' ;; esac; exit 0 ;;
  "output -json") cat "$FAKE_TUNNEL"; exit 0 ;;
esac
exit 0
"""

FAKE_SSH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_SSH_LOG"
case "$*" in
  *"weft-peer pubkey") echo "$FAKE_SERVER_PUB" ;;
esac
"""


@pytest.fixture
def weft(tmp_path):
    for name in ("weft.sh", "lib.sh"):
        shutil.copy(HERE / name, tmp_path / name)
    (tmp_path / ".terraform").mkdir()
    (tmp_path / ".env").write_text("TF_VAR_cloud=vultr\n")
    (tmp_path / "terraform.tfvars").write_text('hostname = "default-box.example.invalid"\n')
    (tmp_path / "workspaces").mkdir()
    (tmp_path / "workspaces" / "egress-test.tfvars").write_text('hostname = "egress-test"\n')
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    write_exe(bindir / "terraform", FAKE_TF)
    write_exe(bindir / "ssh", FAKE_SSH)
    state, tunnel = tmp_path / "state", tmp_path / "tunnel.json"
    server_pub = wg_key()

    def run(*args, state_lines=(), tunnel_out=None, extra_env=None):
        state.write_text("".join(f"{l}\n" for l in state_lines))
        tunnel.write_text(json.dumps(tunnel_out))
        logs = {n: tmp_path / f"{n}.log" for n in ("tf", "ssh")}
        env = {k: v for k, v in os.environ.items() if k not in ("TF_WORKSPACE", "WEFT_WORKSPACE",
                                                                  "WEFT_RELEASE_STATIC_IP")}
        env.update(PATH=f"{bindir}:{env['PATH']}", FAKE_LOG=str(logs["tf"]), FAKE_SSH_LOG=str(logs["ssh"]),
                   FAKE_STATE=str(state), FAKE_TUNNEL=str(tunnel), FAKE_SERVER_PUB=server_pub,
                   WEFT_WORKSPACE="egress-test", **(extra_env or {}))
        p = subprocess.run(["bash", str(tmp_path / "weft.sh"), *args], cwd=tmp_path, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        out = {n: (l.read_text().splitlines() if l.exists() else []) for n, l in logs.items()}
        for l in logs.values():
            l.unlink(missing_ok=True)
        return p.returncode, p.stdout, p.stdout + p.stderr, out  # lib.sh reports on stdout

    run.server_pub = server_pub
    return run


STATIC = ["vultr_instance.server[0]", "vultr_reserved_ip.static[0]", "vultr_firewall_group.server[0]"]


@pytest.mark.parametrize("held", ["vultr_reserved_ip.static[0]", "aws_eip.static[0]"])
def test_destroy_refuses_to_release_a_static_ip(weft, held):
    rc, _, err, logs = weft("destroy", state_lines=["vultr_instance.server[0]", held])
    assert rc == 1 and "203.0.114.7" in err and "rebuild" in err
    assert not [c for c in logs["tf"] if c.startswith("destroy")]


def test_destroy_releases_a_static_ip_only_when_told_and_runs_plain_without_one(weft):
    rc, _, err, logs = weft("destroy", state_lines=STATIC, extra_env={"WEFT_RELEASE_STATIC_IP": "1"})
    assert rc == 0 and "will be released" in err
    assert "destroy -var-file=workspaces/egress-test.tfvars" in logs["tf"]
    rc, _, _, logs = weft("destroy", state_lines=["vultr_instance.server[0]"])
    assert rc == 0 and "destroy -var-file=workspaces/egress-test.tfvars" in logs["tf"]


@pytest.mark.parametrize("server", ["vultr_instance.server[0]", "aws_instance.server[0]"])
def test_rebuild_replaces_only_the_server(weft, server):
    rc, _, _, logs = weft("rebuild", "-auto-approve", state_lines=[server, "vultr_reserved_ip.static[0]"])
    assert rc == 0
    assert f"apply -replace={server} -var-file=workspaces/egress-test.tfvars -auto-approve" in logs["tf"]


def test_rebuild_without_a_server_is_refused(weft):
    rc, _, err, logs = weft("rebuild", state_lines=[])
    assert rc == 1 and "No server" in err and not [c for c in logs["tf"] if c.startswith("apply")]


TUN = {"endpoint": "203.0.114.7:51820", "port": 51820, "cidr": "10.77.0.0/24", "server_address": "10.77.0.1"}


def test_tunnel_client_config_builds_a_config_weft_tunnel_accepts(weft, tmp_path):
    cg = "user.slice/user-1000.slice/user@1000.service/app.slice"
    rc, out, err, logs = weft("tunnel", "client-config", "box", "10.77.0.5", "--cgroup", cg,
                              "--bypass", "198.51.100.10", tunnel_out=TUN)
    assert rc == 0, err
    cfg = json.loads(out)
    assert cfg == {"name": "box", "endpoint": "203.0.114.7:51820", "server_public_key": weft.server_pub,
                   "address": "10.77.0.5/24", "cgroups": [cg], "bypass": ["198.51.100.10"]}
    assert logs["ssh"] and logs["ssh"][0].endswith("ops@203.0.114.7 sudo weft-peer pubkey")
    p = tmp_path / "box.json"
    p.write_text(out)
    assert wt.load_config(p)["iface"] == "weft-box"


def test_tunnel_client_config_can_ask_to_go_direct_while_the_tunnel_is_down(weft, tmp_path):
    rc, out, err, _ = weft("tunnel", "client-config", "box", "10.77.0.5", "--cgroup", "a.slice",
                           "--on-failure", "direct", tunnel_out=TUN)
    assert rc == 0, err
    cfg = json.loads(out)
    assert (cfg["on_failure"], cfg["server_address"]) == ("direct", "10.77.0.1")
    p = tmp_path / "box.json"
    p.write_text(out)
    assert wt.load_config(p)["on_failure"] == "direct"


@pytest.mark.parametrize("args, words", [
    (("client-config", "box", "10.78.0.5", "--cgroup", "a.slice"), "outside the tunnel network"),
    (("client-config", "box", "10.77.0.5"), "at least one --cgroup"),
    (("client-config", "box", "10.77.0.5", "--cgroup"), "unexpected argument"),
    (("client-config", "box", "10.77.0.5", "--cgroup", "a.slice", "--on-failure", "open"), "closed or direct"),
    (("add-peer", "box"), "usage"),
])
def test_tunnel_client_config_and_add_peer_refuse_bad_arguments(weft, args, words):
    rc, _, err, _ = weft("tunnel", *args, tunnel_out=TUN)
    assert rc != 0 and words in err


def test_tunnel_commands_need_a_tunnel_server_and_quote_remote_arguments(weft):
    rc, _, err, logs = weft("tunnel", "peers", tunnel_out=None)
    assert rc == 1 and "not a tunnel egress" in err and logs["ssh"] == []
    key = wg_key()
    rc, _, _, logs = weft("tunnel", "add-peer", "box", key, "10.77.0.5", tunnel_out=TUN)
    assert rc == 0 and logs["ssh"][0].endswith(f"ops@203.0.114.7 sudo weft-peer add box {key} 10.77.0.5")
    rc, _, _, logs = weft("tunnel", "remove-peer", "box; reboot", tunnel_out=TUN)
    assert logs["ssh"][0].endswith("sudo weft-peer remove box\\;\\ reboot")


def test_tunnel_help_needs_no_server(weft):
    rc, out, _, logs = weft("tunnel", tunnel_out=None)
    assert rc == 0 and "client-config" in out and logs["ssh"] == []


# --- install-client.sh -------------------------------------------------------------------------------------------

def _wg_dir() -> str:
    return os.environ.get("WG_BIN") or (str(Path(shutil.which("wg")).parent) if shutil.which("wg") else "")


@pytest.fixture
def installer(tmp_path):
    """install-client.sh as fake root (unshare -r) under a scratch root, with modprobe/systemctl/apt-get stubbed."""
    if not _wg_dir() or not shutil.which("unshare"):
        pytest.skip("needs WireGuard tools (wg; or WG_BIN=dir) and unshare")
    if subprocess.run(["unshare", "-r", "true"], capture_output=True).returncode != 0:
        pytest.skip("user namespaces are not available")
    root = tmp_path / "root"
    for d in ("usr/local/sbin", "etc/systemd/system", "etc/modules-load.d"):
        (root / d).mkdir(parents=True)
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    calls = tmp_path / "calls.log"
    for cmd in ("modprobe", "systemctl", "apt-get"):
        write_exe(stubs / cmd, f'#!/bin/sh\necho "{cmd} $*" >> "{calls}"\n')

    def run(*args, fake_root=True):
        env = {**os.environ, "WEFT_INSTALL_ROOT": str(root), "PATH": f"{stubs}:{_wg_dir()}:{os.environ['PATH']}"}
        argv = ["sh", str(TUNNEL / "install-client.sh"), *map(str, args)]
        p = subprocess.run((["unshare", "-r"] if fake_root else []) + argv, env=env, capture_output=True, text=True,
                           timeout=60)
        return p, (calls.read_text().splitlines() if calls.exists() else [])

    def config(**changes):
        raw = {**GOOD, "name": "box", "private_key_file": str(root / "etc/weft/tunnel/box.key"), **changes}
        p = tmp_path / "box.json"
        p.write_text(json.dumps(raw))
        return p

    run.root, run.config = root, config
    return run


def test_install_client_installs_the_service_config_and_a_private_key(installer):
    cfg = installer.config()
    p, calls = installer(cfg)
    assert p.returncode == 0, p.stdout + p.stderr
    root = installer.root
    tun = root / "etc/weft/tunnel"
    assert (root / "usr/local/sbin/weft-tunnel").read_bytes() == (TUNNEL / "weft_tunnel.py").read_bytes()
    assert stat.S_IMODE((root / "usr/local/sbin/weft-tunnel").stat().st_mode) == 0o755
    assert (root / "etc/systemd/system/weft-tunnel@.service").read_text() == (TUNNEL / "weft-tunnel@.service").read_text()
    assert (tun / "box.json").read_bytes() == cfg.read_bytes()
    assert stat.S_IMODE((tun / "box.json").stat().st_mode) == 0o644
    assert stat.S_IMODE(tun.stat().st_mode) == 0o755
    assert (root / "etc/modules-load.d/weft-tunnel.conf").read_text() == "wireguard\n"
    key = tun / "box.key"
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    pub = subprocess.run([str(Path(_wg_dir()) / "wg"), "pubkey"], input=key.read_text(), capture_output=True,
                         text=True, check=True).stdout.strip()
    assert f"./weft.sh tunnel add-peer box {pub} 10.77.0.2" in p.stdout
    assert calls == ["modprobe wireguard", "systemctl daemon-reload"]  # wg is on PATH: no apt-get; no start


def test_install_client_keeps_the_key_and_backs_up_a_changed_config(installer):
    p, _ = installer(installer.config())
    assert p.returncode == 0, p.stderr
    tun = installer.root / "etc/weft/tunnel"
    key = (tun / "box.key").read_text()
    p, _ = installer(installer.config(address="10.77.0.9/24"))
    assert p.returncode == 0, p.stderr
    assert (tun / "box.key").read_text() == key
    assert json.loads((tun / "box.json").read_text())["address"] == "10.77.0.9/24"
    backups = list(tun.glob("box.json.*.bak"))
    assert len(backups) == 1 and json.loads(backups[0].read_text())["address"] == "10.77.0.2/24"


def test_install_client_refuses_a_bad_config_before_installing_anything(installer):
    p, calls = installer(installer.config(address="10.99.0.2/24", endpoint="not an endpoint"))
    assert p.returncode != 0 and "refused" in p.stderr
    assert calls == [] and not (installer.root / "etc/weft").exists()
    assert not (installer.root / "usr/local/sbin/weft-tunnel").exists()


def test_install_client_refuses_to_run_unprivileged(installer):
    p, calls = installer(installer.config(), fake_root=False)
    assert p.returncode != 0 and "run as root" in p.stderr
    assert calls == [] and not (installer.root / "etc/weft").exists()


# --- end to end ----------------------------------------------------------------------------------------------------

def test_tunnel_end_to_end_in_rootless_namespaces():
    wg_bin = os.environ.get("WG_BIN") or (str(Path(shutil.which("wg")).parent) if shutil.which("wg") else "")
    if not wg_bin or not shutil.which("unshare"):
        pytest.skip("needs WireGuard tools (wg, wg-quick; or WG_BIN=dir) and unshare")
    p = subprocess.run(["bash", str(TUNNEL / "test_tunnel_netns.sh")], env={**os.environ, "WG_BIN": wg_bin},
                       capture_output=True, text=True, timeout=180)
    if p.returncode == 77:
        pytest.skip(p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "netns test skipped")
    assert p.returncode == 0, p.stdout[-3000:] + p.stderr[-2000:]
    assert "all tunnel checks passed" in p.stdout
