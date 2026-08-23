#!/usr/bin/env bash
# Interactive setup for weft. Installs what's missing, opens the pages you need,
# asks for the handful of things only you can answer, and offers to build the
# server at the end. Safe to re-run: it keeps what's already configured.
set -uo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"
source ./lib.sh

need_tty

printf '%s\n' "${C_B}Weft setup${C_OFF}"
info "One hardened Ubuntu server, on Vultr or AWS."

# =========================================================================
step "1/7  Terraform"
# =========================================================================

install_terraform() {
  case "$OSTYPE" in
    linux-gnu*)
      info "Adding the HashiCorp APT repo (needs sudo)..."
      curl -fsSL https://apt.releases.hashicorp.com/gpg |
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg || return 1
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" |
        sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null || return 1
      sudo apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/hashicorp.list -o Dir::Etc::sourceparts=/dev/null || return 1
      sudo apt-get install -y -qq terraform || return 1
      ;;
    darwin*)
      command -v brew >/dev/null 2>&1 || { open_url "https://brew.sh" "Homebrew install page"; return 1; }
      brew install terraform || return 1
      ;;
    *) return 1 ;;
  esac
}

if command -v terraform >/dev/null 2>&1; then
  ok "Terraform $(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || echo installed)"
else
  bad "Terraform is not installed"
  if confirm "Install it now?" Y; then
    install_terraform && ok "Terraform $(terraform version -json | jq -r .terraform_version)" || {
      open_url "https://developer.hashicorp.com/terraform/install" "Terraform install page"
      die "Couldn't install terraform automatically."
    }
  else
    die "Weft needs terraform."
  fi
fi

# =========================================================================
step "2/7  SSH key"
# =========================================================================

SSH_KEY="${HOME}/.ssh/id_ed25519"

if [ -f "${SSH_KEY}.pub" ]; then
  ok "Using ${SSH_KEY}.pub"
else
  warn "No SSH key at ${SSH_KEY}.pub"
  if confirm "Generate one now (no passphrase)?" Y; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q -C "weft@$(hostname)" || die "ssh-keygen failed."
    ok "Created ${SSH_KEY}.pub"
  else
    die "Weft needs an SSH key to put on the server."
  fi
fi

# =========================================================================
step "3/7  Cloud"
# =========================================================================

env_load
CLOUD="$(env_get TF_VAR_cloud)"

if [ -n "$CLOUD" ]; then
  ok "Using ${CLOUD} (from .env)"
  confirm "Keep using ${CLOUD}?" Y || CLOUD=""
fi

if [ -z "$CLOUD" ]; then
  pick CLOUD "Which cloud?" \
    "vultr|Vultr -- flat pricing, from \$5/mo, quick to set up" \
    "aws|AWS -- EC2 in your default VPC, per-second billing"
  case "$CLOUD" in
    vultr|aws) ;;
    *) die "Expected 'vultr' or 'aws', got '${CLOUD}'." ;;
  esac
fi
env_set TF_VAR_cloud "$CLOUD"
export TF_VAR_cloud="$CLOUD"
ok "Cloud: ${CLOUD}"

# =========================================================================
step "4/7  Credentials"
# =========================================================================

MY_IP="$(my_ip)"

# -> 0 ok, 1 bad key, 2 IP not allowlisted, 3 unreachable.
# No -f: curl would swallow the error body, and the body is the only thing that
# says whether the key is wrong or just the IP. Vultr names the IP it saw, which
# beats guessing ours from outside (NAT, IPv6, VPNs).
VULTR_MSG=""
VULTR_BLOCKED_IP=""
vultr_probe() {
  local out code
  out="$(curl -sSL -m 15 -w $'\n%{http_code}' \
    -H "Authorization: Bearer ${1}" https://api.vultr.com/v2/account 2>/dev/null)"
  code="$(printf '%s' "$out" | tail -1)"
  VULTR_MSG="$(printf '%s' "$out" | sed '$d' | jq -r '.error // empty' 2>/dev/null)"
  case "$code" in
    200) return 0 ;;
    401|403)
      case "$VULTR_MSG" in
        *"Unauthorized IP"*)
          VULTR_BLOCKED_IP="$(printf '%s' "$VULTR_MSG" | grep -oE '[0-9a-fA-F.:]+$')"
          return 2
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 3 ;;
  esac
}

setup_vultr_creds() {
  local key
  key="$(env_get TF_VAR_vultr_api_key)"

  while :; do
    if [ -z "$key" ]; then
      info "Weft needs a Vultr API key. The page is opening now:"
      info "  Account > API > Enable API, then copy the key."
      open_url "https://my.vultr.com/settings/#settingsapi" "Vultr API settings"
      ask_secret key "Paste your Vultr API key"
      [ -n "$key" ] || { warn "Nothing pasted."; continue; }
      env_set TF_VAR_vultr_api_key "$key"
    fi

    printf '  checking the key... '
    vultr_probe "$key"; local rc=$?
    printf '\n'

    case $rc in
      0) ok "Vultr API works"; export TF_VAR_vultr_api_key="$key"; return 0 ;;
      1)
        bad "Vultr says: ${VULTR_MSG:-that key is invalid}"
        key=""
        confirm "Try another key?" Y || return 1
        ;;
      2)
        local blocked="${VULTR_BLOCKED_IP:-$MY_IP}"
        warn "The key is fine, but Vultr is blocking this machine (${blocked:-unknown IP})"
        [ -n "$blocked" ] && clip "$blocked" "IP ${blocked}"
        info "On the page opening now, under 'Access Control', add ${blocked:-your IP}"
        info "(or tick 'Allow All IPv4'), then come back here -- weft will notice."
        open_url "https://my.vultr.com/settings/#settingsapi" "Vultr API settings"
        printf '  waiting for the allowlist'
        local i
        for i in $(seq 1 60); do
          sleep 5
          printf '.'
          if vultr_probe "$key"; then
            printf '\n'; ok "Vultr API works"
            export TF_VAR_vultr_api_key="$key"; return 0
          fi
        done
        printf '\n'
        warn "Still blocked after 5 minutes."
        confirm "Keep waiting?" Y || return 1
        ;;
      3)
        bad "Couldn't reach api.vultr.com -- check your connection"
        confirm "Retry?" Y || return 1
        ;;
    esac
  done
}

setup_aws_creds() {
  # Anything the AWS SDKs already accept works; only prompt if nothing is there.
  local have=""
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    have="access key from .env / environment"
  elif [ -n "$(env_get TF_VAR_aws_profile)" ]; then
    have="profile '$(env_get TF_VAR_aws_profile)'"
  elif [ -n "${AWS_PROFILE:-}" ]; then
    have="profile '${AWS_PROFILE}' from the environment"
  elif [ -f "${HOME}/.aws/credentials" ] || [ -f "${HOME}/.aws/config" ]; then
    have="the default profile in ~/.aws"
  fi

  if [ -n "$have" ]; then
    ok "Found AWS credentials: ${have}"
    confirm "Use them?" Y && return 0
  fi

  if [ -f "${HOME}/.aws/credentials" ]; then
    local profiles
    profiles="$(grep -o '^\[[^]]*\]' "${HOME}/.aws/credentials" 2>/dev/null | tr -d '[]' | tr '\n' ' ')"
    [ -n "$profiles" ] && info "Profiles in ~/.aws/credentials: ${profiles}"
  fi

  info "Weft needs an AWS access key. The page is opening now:"
  info "  Security credentials > Create access key > copy both halves."
  open_url "https://console.aws.amazon.com/iam/home#/security_credentials" "AWS security credentials"

  local id secret
  ask id "Access key ID (or blank to name a ~/.aws profile instead)"
  if [ -z "$id" ]; then
    local prof
    ask prof "Profile name" "default"
    env_set TF_VAR_aws_profile "$prof"
    export TF_VAR_aws_profile="$prof"
    ok "Will use profile '${prof}'"
    return 0
  fi
  ask_secret secret "Secret access key"
  [ -n "$secret" ] || die "No secret key given."
  env_set AWS_ACCESS_KEY_ID "$id"
  env_set AWS_SECRET_ACCESS_KEY "$secret"
  export AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$secret"
  ok "Saved to .env (chmod 600)"
  info "Weft checks them for real when it plans, in step 7."
}

if [ "$CLOUD" = "vultr" ]; then
  setup_vultr_creds || die "Can't talk to Vultr without a working API key."
else
  setup_aws_creds
fi

# =========================================================================
step "5/7  Region and size"
# =========================================================================

pick_vultr_region() {  # <var>
  local __var="$1" json line
  local -a items=()
  json="$(curl -sSL -m 20 -H "Authorization: Bearer ${TF_VAR_vultr_api_key}" \
    https://api.vultr.com/v2/regions 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] && items+=("$line")
  done < <(printf '%s' "$json" |
    jq -r '.regions | sort_by(.continent, .city)[] | "\(.id)|\(.city), \(.country)  (\(.continent))"' 2>/dev/null)

  if [ "${#items[@]}" -eq 0 ]; then
    warn "Couldn't fetch the live region list; here's a short one."
    items=("ams|Amsterdam" "fra|Frankfurt" "lhr|London" "ewr|New Jersey"
           "ord|Chicago" "sea|Seattle" "sgp|Singapore" "nrt|Tokyo" "syd|Sydney")
  fi
  pick "$__var" "Region?" "${items[@]}"
}

pick_vultr_plan() {  # <var> <region>
  local __var="$1" region="$2" json line
  local -a items=()
  json="$(curl -sSL -m 20 -H "Authorization: Bearer ${TF_VAR_vultr_api_key}" \
    "https://api.vultr.com/v2/plans?per_page=500" 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] && items+=("$line")
  done < <(printf '%s' "$json" | jq -r --arg r "$region" '
    .plans
    | map(select(.locations | index($r)))
    | sort_by(.monthly_cost)[:8][]
    | "\(.id)|\(.vcpu_count) vCPU, \(.ram / 1024) GB RAM, \(.disk) GB disk  --  $\(.monthly_cost)/mo"' 2>/dev/null)

  if [ "${#items[@]}" -eq 0 ]; then
    warn "Couldn't list plans for ${region}; here's the usual lineup."
    items=("vc2-1c-1gb|1 vCPU, 1 GB  --  \$5/mo"
           "vc2-1c-2gb|1 vCPU, 2 GB  --  \$10/mo"
           "vc2-2c-4gb|2 vCPU, 4 GB  --  \$20/mo")
  fi
  pick "$__var" "Size?" "${items[@]}"
}

if [ "$CLOUD" = "vultr" ]; then
  pick_vultr_region REGION
  ok "Region: ${REGION}"
  pick_vultr_plan PLAN "$REGION"
  ok "Size: ${PLAN}"
else
  pick REGION "Region?" \
    "eu-central-1|Frankfurt" "eu-west-1|Ireland" "eu-north-1|Stockholm" "eu-west-2|London" \
    "us-east-1|N. Virginia" "us-west-2|Oregon" \
    "ap-southeast-1|Singapore" "ap-southeast-2|Sydney" "ap-northeast-1|Tokyo"
  ok "Region: ${REGION}"
  pick PLAN "Size?" \
    "t3.micro|2 vCPU, 1 GB  --  cheapest, free-tier eligible" \
    "t3.small|2 vCPU, 2 GB" \
    "t3.medium|2 vCPU, 4 GB" \
    "t4g.small|2 vCPU, 2 GB  --  Arm/Graviton, a bit cheaper"
  ok "Size: ${PLAN}"
  case "$PLAN" in
    t4g.*|m7g.*|c7g.*|r7g.*|m6g.*|c6g.*|r6g.*)
      tfvars_set aws_architecture '"arm64"'
      info "Arm instance, so weft will use the arm64 AMI" ;;
    *) tfvars_set aws_architecture '"amd64"' ;;
  esac
fi

tfvars_set region "\"${REGION}\""
tfvars_set plan "\"${PLAN}\""

ask_until HOST "Hostname" "weft" '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' \
  "Hostnames are letters, digits and dashes, starting and ending with a letter or digit."
tfvars_set hostname "\"${HOST}\""

if [ -n "$MY_IP" ]; then
  if confirm "Lock SSH to this machine's IP (${MY_IP}) instead of the whole internet?" N; then
    tfvars_set ssh_allowed_cidrs "[\"${MY_IP}/32\"]"
    ok "Port 22 restricted to ${MY_IP}/32"
    info "If your IP changes, re-run setup or edit terraform.tfvars."
  else
    tfvars_set ssh_allowed_cidrs '["0.0.0.0/0"]'
  fi
fi

info "Saved to terraform.tfvars -- weft reads it automatically."

# =========================================================================
step "6/7  Providers"
# =========================================================================

if terraform init -input=false >/dev/null 2>&1; then
  ok "Terraform initialised"
else
  bad "terraform init failed:"
  terraform init -input=false 2>&1 | tail -15
  die "Fix the above and re-run ./setup.sh"
fi

# =========================================================================
step "7/7  Plan"
# =========================================================================

install_awscli() {
  local arch tmp url
  case "$OSTYPE" in
    darwin*)
      command -v brew >/dev/null 2>&1 || return 1
      brew install awscli >/dev/null 2>&1 || return 1
      return 0
      ;;
    linux-gnu*) ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) return 1 ;;
  esac
  url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
  tmp="$(mktemp -d)"
  curl -fsSL -m 300 "$url" -o "$tmp/awscli.zip" &&
    unzip -qq "$tmp/awscli.zip" -d "$tmp" &&
    "$tmp/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$HOME/.local/bin" --update >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
  return $rc
}

create_default_vpc() {
  if ! command -v aws >/dev/null 2>&1; then
    warn "There's no default VPC in ${REGION}, and no AWS CLI here to make one."
    if confirm "Install the AWS CLI (into ~/.local, no sudo) so weft can create it?" Y; then
      install_awscli && ok "AWS CLI installed" || warn "Couldn't install it."
    fi
  fi
  if command -v aws >/dev/null 2>&1; then
    info "Creating a default VPC in ${REGION}..."
    if aws ec2 create-default-vpc --region "$REGION" >/dev/null 2>&1; then
      ok "Default VPC created"
      return 0
    fi
    warn "The API refused (often means the account has no permission for it)."
  fi
  info "Create one by hand: VPC console > Actions > Create default VPC."
  open_url "https://${REGION}.console.aws.amazon.com/vpcconsole/home?region=${REGION}#vpcs:" "VPC console"
  confirm "Press y once that's done" Y
}

PLAN_LOG="$(mktemp)"
trap 'rm -f "$PLAN_LOG" weft.tfplan' EXIT

plan_ok=0
for attempt in 1 2 3 4 5; do
  printf '  planning... '
  if terraform plan -input=false -out=weft.tfplan >"$PLAN_LOG" 2>&1; then
    printf '\n'; ok "Plan is good"
    plan_ok=1
    break
  fi
  printf '\n'

  if grep -qE 'No valid credential sources|InvalidClientTokenId|SignatureDoesNotMatch|AuthFailure|could not be found' "$PLAN_LOG"; then
    bad "AWS rejected those credentials"
    env_unset AWS_ACCESS_KEY_ID; env_unset AWS_SECRET_ACCESS_KEY
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    setup_aws_creds
    continue
  fi
  if grep -q 'no matching EC2 VPC found' "$PLAN_LOG"; then
    create_default_vpc
    continue
  fi
  if grep -qi 'Unauthorized IP address' "$PLAN_LOG"; then
    setup_vultr_creds || break
    continue
  fi
  if grep -qE 'UnauthorizedOperation|AccessDenied|not authorized to perform' "$PLAN_LOG"; then
    bad "Those credentials work but lack permissions:"
    grep -oE '[a-z0-9]+:[A-Za-z]+' "$PLAN_LOG" | sort -u | head -8 | sed 's/^/      needs /'
    break
  fi

  bad "Plan failed:"
  tail -20 "$PLAN_LOG" | sed 's/^/    /'
  break
done

if [ "$plan_ok" != 1 ]; then
  printf '\n'
  warn "Setup got as far as it can. Everything you chose is saved, so once the"
  warn "problem above is sorted, just run ./setup.sh again (or ./weft.sh plan)."
  exit 1
fi

grep -E '^Plan:' "$PLAN_LOG" | sed 's/^/  /'

# =========================================================================
step "Build it?"
# =========================================================================

if ! confirm "Create the server now?" Y; then
  printf '\n'
  ok "Setup complete."
  info "When you're ready:  ./weft.sh apply"
  exit 0
fi

if ! terraform apply -input=false weft.tfplan; then
  die "Apply failed. Nothing else to do here -- see the error above."
fi

IP="$(terraform output -raw server_ip 2>/dev/null)"
[ -n "$IP" ] || die "Applied, but no IP came back. Try ./weft.sh status"
ok "Server at ${IP}"

step "Waiting for it to finish booting"
info "cloud-init takes a minute or two on first boot."
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o LogLevel=ERROR)
ready=0
printf '  '
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "ops@${IP}" true 2>/dev/null; then
    printf '\n'; ok "SSH is up"
    ssh "${SSH_OPTS[@]}" "ops@${IP}" 'sudo cloud-init status --wait >/dev/null 2>&1; sudo cloud-init status' 2>/dev/null |
      sed 's/^/  /'
    ready=1
    break
  fi
  printf '.'
  sleep 5
done
[ "$ready" = 1 ] || warn "Still no SSH. Try ./weft.sh ssh in a minute."

printf '\n'
ok "Done."
info "  ./weft.sh ssh         connect as ops"
info "  ./weft.sh ip          print the IP"
info "  ./weft.sh destroy     tear it down"

if [ "$ready" = 1 ] && confirm "Connect now?" Y; then
  rm -f "$PLAN_LOG" weft.tfplan   # exec skips the EXIT trap
  exec ssh -o StrictHostKeyChecking=accept-new "ops@${IP}"
fi
