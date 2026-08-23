#!/usr/bin/env bash
set -uo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"
source ./lib.sh

env_load

cmd="${1:-help}"
shift || true

# Nothing configured yet? Don't lecture, just start setup.
configured() { [ -n "$(env_get TF_VAR_cloud)" ] && [ -d .terraform ]; }

case "$cmd" in
  setup)
    exec ./setup.sh
    ;;
esac

case "$cmd" in
  plan|apply|destroy|ssh|ip|status|cloud-init|test)
    if ! configured; then
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

case "$cmd" in
  init)
    terraform init "$@"
    ;;

  plan)
    terraform plan "$@"
    ;;

  apply)
    terraform apply "$@"
    ip="$(terraform output -raw server_ip 2>/dev/null)" || true
    [ -n "$ip" ] && { printf '\n'; ok "Server at ${ip}"; info "  ./weft.sh ssh   (wait a minute for cloud-init)"; }
    ;;

  destroy)
    terraform destroy "$@"
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
    exec ./smoke-test.sh "$(env_get TF_VAR_cloud)" "$@"
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
