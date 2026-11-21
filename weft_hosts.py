#!/usr/bin/env python3
"""weft_hosts.py — Read-only machine inventory from Terraform workspaces.

Uses only `terraform workspace list` and `terraform show -json` (read-only), or reads
recorded `terraform show -json` files for offline testing.

    ./weft.sh hosts --json
    python3 weft_hosts.py --json [--weft-dir DIR] [--from-json-dir DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SERVER_TYPES = {
    "vultr_instance": "vultr",
    "vultr_bare_metal_server": "vultr",
    "aws_instance": "aws",
}


def _extract_host(workspace: str, outputs: dict, server: dict, inferred_cloud: str) -> dict:
    def out_val(key: str) -> str | None:
        row = outputs.get(key)
        if isinstance(row, dict) and not row.get("sensitive"):
            val = row.get("value")
            return str(val) if val is not None else None
        return None

    ip = (
        out_val("server_ip")
        or server.get("main_ip")
        or server.get("public_ip")
        or ""
    )
    cloud = out_val("server_cloud") or inferred_cloud or ""
    region = out_val("server_region") or server.get("region") or ""
    tags = server.get("tags") or {}
    tags_all = server.get("tags_all") or {}
    hostname = (
        server.get("hostname")
        or server.get("label")
        or (tags.get("Name") if isinstance(tags, dict) else None)
        or (tags_all.get("Name") if isinstance(tags_all, dict) else None)
        or workspace
    )
    plan = server.get("plan") or server.get("instance_type") or ""
    return {
        "workspace": workspace,
        "hostname": str(hostname),
        "ip": str(ip),
        "region": str(region),
        "plan": str(plan),
        "cloud": str(cloud),
    }


def parse_show_json(workspace: str, doc: dict) -> dict | None:
    """Extract {workspace, hostname, ip, region, plan, cloud} from `terraform show -json` output.

    Returns None when the workspace holds no provisioned server resource.
    """
    values = doc.get("values") or {}
    outputs = values.get("outputs") or {}
    root_mod = values.get("root_module") or {}
    resources = root_mod.get("resources") or []
    server = None
    inferred_cloud = None
    for res in resources:
        rtype = res.get("type")
        if rtype in SERVER_TYPES:
            server = res.get("values") or {}
            inferred_cloud = SERVER_TYPES[rtype]
            break
    if server is None:
        return None
    return _extract_host(workspace, outputs, server, inferred_cloud)


def parse_tfstate_json(workspace: str, doc: dict) -> dict | None:
    """Extract {workspace, hostname, ip, region, plan, cloud} from raw local terraform.tfstate JSON.

    Returns None when the workspace holds no provisioned server resource.
    """
    outputs = doc.get("outputs") or {}
    resources = doc.get("resources") or []
    server = None
    inferred_cloud = None
    for res in resources:
        if res.get("mode") not in (None, "managed"):
            continue
        rtype = res.get("type")
        if rtype in SERVER_TYPES:
            instances = res.get("instances") or []
            if instances:
                server = instances[0].get("attributes") or {}
                inferred_cloud = SERVER_TYPES[rtype]
                break
    if server is None:
        return None
    return _extract_host(workspace, outputs, server, inferred_cloud)


def _uses_remote_backend(weft_dir: Path) -> bool:
    backend_state = weft_dir / ".terraform" / "terraform.tfstate"
    if not backend_state.is_file():
        return False
    try:
        doc = json.loads(backend_state.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    btype = (doc.get("backend") or {}).get("type")
    return bool(btype and btype != "local")


def collect_local_tfstates(weft_dir: Path) -> list[dict] | None:
    """Fast path: read local terraform.tfstate files directly (avoids ~3 s per workspace terraform startup).

    Returns None when a remote backend is configured or no local state exists.
    """
    if _uses_remote_backend(weft_dir):
        return None
    state_files: list[tuple[str, Path]] = []
    default_state = weft_dir / "terraform.tfstate"
    if default_state.is_file():
        state_files.append(("default", default_state))
    ws_root = weft_dir / "terraform.tfstate.d"
    if ws_root.is_dir():
        for child in sorted(ws_root.iterdir()):
            sf = child / "terraform.tfstate"
            if child.is_dir() and sf.is_file():
                state_files.append((child.name, sf))
    if not state_files:
        return None
    hosts: list[dict] = []
    for ws, sf in sorted(state_files, key=lambda item: item[0]):
        row = parse_tfstate_json(ws, json.loads(sf.read_text(encoding="utf-8")))
        if row is not None:
            hosts.append(row)
    return hosts


def list_workspaces(weft_dir: Path) -> list[str]:
    p = subprocess.run(
        ["terraform", f"-chdir={weft_dir}", "workspace", "list"],
        capture_output=True,
        text=True,
        check=True,
    )
    names: list[str] = []
    for line in p.stdout.splitlines():
        name = line.lstrip("*").strip()
        if name:
            names.append(name)
    return sorted(names)


def show_workspace_json(weft_dir: Path, workspace: str) -> dict:
    env = {**os.environ, "TF_WORKSPACE": workspace}
    p = subprocess.run(
        ["terraform", f"-chdir={weft_dir}", "show", "-json"],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(p.stdout)


def collect_hosts(
    weft_dir: Path,
    *,
    from_json_dir: Path | None = None,
    via_terraform: bool = False,
) -> list[dict]:
    hosts: list[dict] = []
    if from_json_dir is not None:
        for p in sorted(Path(from_json_dir).glob("*.json")):
            ws = p.stem
            row = parse_show_json(ws, json.loads(p.read_text(encoding="utf-8")))
            if row is not None:
                hosts.append(row)
        return hosts

    if not via_terraform:
        local = collect_local_tfstates(weft_dir)
        if local is not None:
            return local

    for ws in list_workspaces(weft_dir):
        doc = show_workspace_json(weft_dir, ws)
        row = parse_show_json(ws, doc)
        if row is not None:
            hosts.append(row)
    return hosts


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="weft.sh hosts", description=__doc__)
    p.add_argument("--json", action="store_true", help="Emit JSON array")
    p.add_argument("--weft-dir", type=Path, default=Path(__file__).resolve().parent)
    p.add_argument("--from-json-dir", type=Path, default=None, help="Offline directory of <ws>.json files")
    p.add_argument("--via-terraform", action="store_true", help="Force terraform CLI instead of local tfstate fast path")
    args = p.parse_args(argv)
    try:
        hosts = collect_hosts(args.weft_dir, from_json_dir=args.from_json_dir, via_terraform=args.via_terraform)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"weft hosts: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(hosts, indent=2, sort_keys=True))
    else:
        for h in hosts:
            print(
                f"{h['workspace']:20s} {h['hostname']:20s} {h['ip']:16s} "
                f"{h['cloud']:6s} {h['region']:12s} {h['plan']}"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
