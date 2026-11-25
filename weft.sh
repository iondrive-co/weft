#!/usr/bin/env bash
set -uo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"
source ./lib.sh

env_load
[ -n "${WEFT_WORKSPACE:-}" ] && export TF_WORKSPACE="$WEFT_WORKSPACE"

cmd="${1:-help}"
shift || true

# Nothing configured yet? Don't lecture, just start setup.
configured() { [ -n "$(env_get TF_VAR_cloud)" ] && [ -d .terraform ]; }

case "$cmd" in
  setup)
    ws="${TF_WORKSPACE:-$(terraform workspace show 2>/dev/null || echo default)}"
    [ "$ws" = "default" ] || die "Refusing 'setup' in non-default workspace '${ws}': switch to 'default' first."
    exec ./setup.sh
    ;;
esac

case "$cmd" in
  plan|apply|destroy|rebuild|ssh|ip|status|cloud-init|test|tunnel)
    if ! configured; then
      if [ ! -t 0 ]; then
        die "Weft isn't set up yet (non-interactive; run './weft.sh setup')."
      fi
      warn "Weft isn't set up yet -- starting setup."
      exec ./setup.sh
    fi
    ;;
esac

server_ip() {
  local ip
  ip="$(terraform output -raw server_ip 2>/dev/null)" || true
  if [ -z "$ip" ]; then
    bad "No server yet. Run './weft.sh apply' first."
    exit 1
  fi
  printf '%s' "$ip"
}

WORKSPACE_VAR_FILE=""
resolve_workspace_var_file() {
  local ws has_explicit=0 arg prev=""
  WORKSPACE_VAR_FILE=""
  ws="${TF_WORKSPACE:-$(terraform workspace show 2>/dev/null || echo default)}"
  [ "$ws" = "default" ] && return 0
  if [ -f "workspaces/${ws}.tfvars" ]; then
    WORKSPACE_VAR_FILE="workspaces/${ws}.tfvars"
    return 0
  fi
  for arg in "$@"; do
    if [ "$prev" = "-var" ]; then
      case "$arg" in
        hostname=*) has_explicit=1 ;;
      esac
      prev=""
      continue
    fi
    case "$arg" in
      -var-file|-var-file=*|-var=hostname=*) has_explicit=1 ;;
      -var) prev="-var" ;;
    esac
  done
  if [ "$has_explicit" -eq 1 ]; then
    return 0
  fi
  die "Refusing '${cmd}' on non-default workspace '${ws}': missing workspaces/${ws}.tfvars (and no -var-file or -var=hostname=... passed); plain terraform.tfvars would target another server."
}

case "$cmd" in
  init)
    terraform init "$@"
    ;;

  plan)
    resolve_workspace_var_file "$@"
    if [ -n "$WORKSPACE_VAR_FILE" ]; then
      terraform plan -var-file="$WORKSPACE_VAR_FILE" "$@"
    else
      terraform plan "$@"
    fi
    ;;

  apply)
    resolve_workspace_var_file "$@"
    rc=0
    if [ -n "$WORKSPACE_VAR_FILE" ]; then
      terraform apply -var-file="$WORKSPACE_VAR_FILE" "$@" || rc=$?
    else
      terraform apply "$@" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      exit "$rc"
    fi
    ip="$(terraform output -raw server_ip 2>/dev/null)" || true
    [ -n "$ip" ] && { printf '\n'; ok "Server at ${ip}"; info "  ./weft.sh ssh   (wait a minute for cloud-init)"; }
    ;;

  destroy)
    resolve_workspace_var_file "$@"
    # A static IP is what allowlists know the server by; releasing it is never a side effect.
    if terraform state list 2>/dev/null | grep -Eq '^(vultr_reserved_ip|aws_eip)\.static'; then
      if [ "${WEFT_RELEASE_STATIC_IP:-}" != 1 ]; then
        die "Refusing 'destroy': this workspace holds static IP $(terraform output -raw static_ip 2>/dev/null) and destroy would release it for good. Use './weft.sh rebuild' to replace only the server, or set WEFT_RELEASE_STATIC_IP=1 to give the IP up."
      fi
      warn "WEFT_RELEASE_STATIC_IP=1: the static IP $(terraform output -raw static_ip 2>/dev/null) will be released."
    fi
    if [ -n "$WORKSPACE_VAR_FILE" ]; then
      terraform destroy -var-file="$WORKSPACE_VAR_FILE" "$@"
    else
      terraform destroy "$@"
    fi
    ;;

  rebuild)
    # A fresh server from the current cloud-init, keeping everything else (the static IP above all).
    resolve_workspace_var_file "$@"
    target="$(terraform state list 2>/dev/null | grep -E '^(vultr_instance|vultr_bare_metal_server|aws_instance)\.server\[0\]$' | head -n 1)"
    [ -n "$target" ] || die "No server in this workspace to rebuild."
    terraform state list 2>/dev/null | grep -Eq '^(vultr_reserved_ip|aws_eip)\.static' \
      || warn "This workspace has no static IP: the rebuilt server gets a new address."
    warn "Rebuilding ${target}: its disk is wiped, and a tunnel server gets a new WireGuard key (clients need 'tunnel client-config' and 'tunnel add-peer' again)."
    if [ -n "$WORKSPACE_VAR_FILE" ]; then
      terraform apply -replace="$target" -var-file="$WORKSPACE_VAR_FILE" "$@"
    else
      terraform apply -replace="$target" "$@"
    fi
    ;;

  tunnel)
    # Client side of a tunnel egress: everything here runs over SSH as ops, so only public keys ever move.
    sub="${1:-help}"; shift || true
    tunnel_json="$(terraform output -json tunnel 2>/dev/null)" || tunnel_json=null
    if [ "$sub" != help ] && { [ -z "$tunnel_json" ] || [ "$tunnel_json" = null ]; }; then
      die "This workspace's server is not a tunnel egress (set tunnel = true in its tfvars and apply)."
    fi
    if [ "$sub" != help ]; then
      tunnel_host="$(server_ip)" || exit 1
    fi
    remote() { ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "ops@${tunnel_host}" "$@"; }
    case "$sub" in
      pubkey) remote sudo weft-peer pubkey ;;
      peers) remote sudo weft-peer list ;;
      add-peer)
        [ $# -eq 3 ] || die "usage: ./weft.sh tunnel add-peer NAME CLIENT_PUBKEY ADDRESS"
        remote sudo weft-peer add "$(printf '%q' "$1")" "$(printf '%q' "$2")" "$(printf '%q' "$3")"
        ;;
      remove-peer)
        [ $# -eq 1 ] || die "usage: ./weft.sh tunnel remove-peer NAME"
        remote sudo weft-peer remove "$(printf '%q' "$1")"
        ;;
      handshakes) remote sudo wg show wg0 latest-handshakes ;;
      client-config)
        # client-config NAME ADDRESS --cgroup PATH [--cgroup PATH]... [--bypass CIDR]... [--on-failure closed|direct]
        [ $# -ge 2 ] || die "usage: ./weft.sh tunnel client-config NAME ADDRESS --cgroup PATH [--cgroup PATH]... [--bypass IP_OR_CIDR]... [--on-failure closed|direct]"
        name="$1"; address="$2"; shift 2
        server_pub="$(remote sudo weft-peer pubkey)" || die "could not read the server's public key"
        python3 - "$tunnel_json" "$name" "$address" "$server_pub" "$@" <<'PY'
import ipaddress, json, sys
tun, name, address, server_pub, *rest = sys.argv[1:]
tun = json.loads(tun)
cgroups, bypass, on_failure = [], [], None
while rest:
    flag, value, rest = rest[0], (rest[1] if len(rest) > 1 else None), rest[2:]
    if value is None or flag not in ("--cgroup", "--bypass", "--on-failure"):
        sys.exit(f"weft: unexpected argument {flag!r}")
    if flag == "--on-failure":
        if value not in ("closed", "direct"):
            sys.exit(f"weft: --on-failure {value!r}: use closed or direct")
        on_failure = value
    else:
        (cgroups if flag == "--cgroup" else bypass).append(value)
if not cgroups:
    sys.exit("weft: give at least one --cgroup (e.g. user.slice/user-1000.slice/user@1000.service/app.slice)")
net = ipaddress.ip_network(tun["cidr"])
ip = ipaddress.ip_address(address.split("/")[0])
if ip not in net:
    sys.exit(f"weft: {address} is outside the tunnel network {net}")
cfg = {"name": name, "endpoint": tun["endpoint"], "server_public_key": server_pub.strip(),
       "address": f"{ip}/{net.prefixlen}", "cgroups": cgroups}
if bypass:
    cfg["bypass"] = bypass
if on_failure:
    cfg["on_failure"] = on_failure
    if tun.get("server_address"):
        cfg["server_address"] = tun["server_address"]  # what run probes to judge the tunnel's health
print(json.dumps(cfg, indent=2))
PY
        ;;
      help|*)
        cat <<'TUNNEL'
Usage: ./weft.sh tunnel <command>   (on a server applied with tunnel = true)

  pubkey                      The server's WireGuard public key
  peers                       Clients the server admits: NAME PUBKEY ADDRESS
  client-config NAME ADDRESS --cgroup PATH [--cgroup PATH]... [--bypass IP_OR_CIDR]... [--on-failure closed|direct]
                              Print a client config for tunnel/weft_tunnel.py (save it as root to
                              /etc/weft/tunnel/NAME.json on the client). --on-failure: while the
                              tunnel is down, refuse selected traffic (closed, the default) or send
                              it the normal way (direct)
  add-peer NAME PUBKEY ADDRESS
                              Admit a client (its public key from 'weft-tunnel keygen')
  remove-peer NAME            Drop a client
  handshakes                  Last handshake time of each client

On the client: tunnel/install-client.sh installs weft-tunnel and its service (see README, "Tunnel egress").
TUNNEL
        ;;
    esac
    ;;

  ssh)
    ip="$(server_ip)"
    info "Connecting to ops@${ip}..."
    ssh -o StrictHostKeyChecking=accept-new "ops@${ip}" "$@"
    ;;

  ip)
    server_ip
    printf '\n'
    ;;

  hosts)
    exec python3 "$WEFT_DIR/weft_hosts.py" --weft-dir "$WEFT_DIR" "$@"
    ;;

  workspace)
    sub="${1:-list}"
    shift || true
    case "$sub" in
      current)
        if [ -n "${TF_WORKSPACE:-}" ]; then
          printf '%s\n' "$TF_WORKSPACE"
        else
          terraform workspace show
        fi
        ;;
      list)
        unset TF_WORKSPACE
        terraform workspace list "$@"
        ;;
      ensure)
        ws="${1:?workspace name required}"
        unset TF_WORKSPACE
        cur="$(terraform workspace show)" || exit 1
        rc=0
        terraform workspace select -or-create "$ws" >/dev/null || rc=$?
        if [ "$rc" -eq 0 ] && [ "$cur" != "$ws" ]; then
          terraform workspace select "$cur" >/dev/null || rc=$?
        fi
        exit "$rc"
        ;;
      delete)
        ws="${1:?workspace name required}"
        unset TF_WORKSPACE
        cur="$(terraform workspace show)"
        if [ "$cur" = "$ws" ]; then
          terraform workspace select default >/dev/null
        fi
        terraform workspace delete "$ws"
        ;;
      *)
        die "Usage: ./weft.sh workspace [current|list|ensure NAME|delete NAME]"
        ;;
    esac
    ;;

  cloud)
    printf 'configured:  %s\n' "$(env_get TF_VAR_cloud)"
    provisioned="$(terraform output -raw server_cloud 2>/dev/null)" || true
    if [ -z "$provisioned" ]; then
      state="$(terraform state list 2>/dev/null)" || true
      case "$state" in
        *vultr_instance*) provisioned="vultr" ;;
        *aws_instance*)   provisioned="aws" ;;
        *)                provisioned="(no server)" ;;
      esac
    fi
    printf 'provisioned: %s\n' "$provisioned"
    ;;

  status)
    terraform show "$@"
    ;;

  cloud-init)
    ip="$(server_ip)"
    info "Checking cloud-init on ${ip}..."
    ssh -o StrictHostKeyChecking=accept-new "ops@${ip}" \
      "sudo cloud-init status && echo && echo '--- last 20 lines ---' && sudo tail -20 /var/log/cloud-init-output.log"
    ;;

  test)
    smoke_ws="${WEFT_SMOKE_WORKSPACE:-weft-smoke}"
    "$WEFT_DIR/weft.sh" workspace ensure "$smoke_ws" || exit 1
    TF_WORKSPACE="$smoke_ws" exec ./smoke-test.sh "$(env_get TF_VAR_cloud)" "$@"
    ;;

  help|*)
    cat <<'USAGE'
Usage: ./weft.sh <command> [terraform args...]

  setup       Interactive setup: installs what's missing, asks what it needs,
              and offers to build the server (safe to re-run)
  init        Initialize Terraform by hand (setup does this for you)
  plan        Preview what will be created/changed
  apply       Create or update the server
  destroy     Tear down the server (refuses to release a static IP unless
              WEFT_RELEASE_STATIC_IP=1)
  rebuild     Replace only the server (fresh disk, current cloud-init); the
              static IP and firewall stay
  tunnel      Tunnel egress clients: pubkey|peers|client-config|add-peer|
              remove-peer|handshakes (./weft.sh tunnel help)
  ssh         SSH into the server as ops
  ip          Print the server IP
  hosts       List provisioned servers across all workspaces (--json)
  workspace   Manage Terraform workspaces (current|list|ensure|delete)
  cloud       Print which cloud is configured/provisioned
  status      Show current Terraform state
  cloud-init  Check cloud-init progress on the server
  test        Provision, run checks, destroy (./smoke-test.sh)

Setup writes your choices to terraform.tfvars and .env, so plain 'apply' does
the right thing. To change something, re-run './weft.sh setup', edit
terraform.tfvars, or pass flags:

  ./weft.sh apply -var="plan=t3.small"
  ./weft.sh apply -var="cloud=aws" -var="region=eu-west-1"
  ./weft.sh apply -auto-approve

Note: -var flags belong on 'apply' (and 'destroy'), not just 'plan'.
USAGE
    ;;
esac
