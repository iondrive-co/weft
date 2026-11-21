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
  plan|apply|destroy|ssh|ip|status|cloud-init|test)
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
    if [ -n "$WORKSPACE_VAR_FILE" ]; then
      terraform destroy -var-file="$WORKSPACE_VAR_FILE" "$@"
    else
      terraform destroy "$@"
    fi
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
  destroy     Tear down the server
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
