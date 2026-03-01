#!/usr/bin/env bash
set -euo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"

# Load API key from .env
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

cmd="${1:-help}"
shift || true

case "$cmd" in
  init)
    terraform init "$@"
    ;;

  plan)
    terraform plan "$@"
    ;;

  apply)
    terraform apply "$@"
    ;;

  destroy)
    terraform destroy "$@"
    ;;

  ssh)
    ip=$(terraform output -raw server_ip 2>/dev/null) || {
      echo "No server found. Run './weft.sh apply' first."
      exit 1
    }
    echo "Connecting to ops@${ip}..."
    ssh -o StrictHostKeyChecking=accept-new "ops@${ip}" "$@"
    ;;

  ip)
    terraform output -raw server_ip 2>/dev/null || {
      echo "No server found. Run './weft.sh apply' first."
      exit 1
    }
    echo ""
    ;;

  status)
    terraform show "$@"
    ;;

  cloud-init)
    ip=$(terraform output -raw server_ip 2>/dev/null) || {
      echo "No server found. Run './weft.sh apply' first."
      exit 1
    }
    echo "Checking cloud-init status on ${ip}..."
    ssh -o StrictHostKeyChecking=accept-new "ops@${ip}" \
      "sudo cloud-init status && echo '' && echo '--- Last 20 lines of cloud-init log ---' && sudo tail -20 /var/log/cloud-init-output.log"
    ;;

  help|*)
    echo "Usage: ./weft.sh <command> [terraform args...]"
    echo ""
    echo "Commands:"
    echo "  init        Initialize Terraform (run once after setup)"
    echo "  plan        Preview what will be created/changed"
    echo "  apply       Create or update the server"
    echo "  destroy     Tear down the server"
    echo "  ssh         SSH into the server as ops"
    echo "  ip          Print the server IP"
    echo "  status      Show current Terraform state"
    echo "  cloud-init  Check cloud-init progress on server"
    echo ""
    echo "Examples:"
    echo "  ./weft.sh plan                          # Preview with defaults"
    echo "  ./weft.sh apply                          # Create with defaults"
    echo "  ./weft.sh apply -var=\"region=ewr\"         # Use New Jersey region"
    echo "  ./weft.sh apply -var=\"plan=vc2-2c-4gb\"   # Bigger server"
    echo "  ./weft.sh apply -auto-approve            # Skip confirmation"
    echo ""
    echo "Note: -var flags must be passed to 'apply' (or 'destroy'), not just 'plan'."
    echo "To avoid repeating flags, put overrides in terraform.tfvars:"
    echo "  echo 'region = \"sgp\"' >> terraform.tfvars"
    echo ""
    echo "API key is read from .env file. Run ./setup.sh to configure."
    ;;
esac
