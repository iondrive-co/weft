#!/usr/bin/env bash
# Provision a server, assert the box came up the way weft intends, then destroy
# it. Takes about four minutes and costs a couple of cents.
#
#   ./smoke-test.sh vultr
#   ./smoke-test.sh aws
#   ./smoke-test.sh aws --keep -var="region=eu-west-1"
#
# --keep leaves the server running (and tells you how to get rid of it).
set -uo pipefail

WEFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WEFT_DIR"

CLOUD="${1:-}"
if [ "$CLOUD" != "vultr" ] && [ "$CLOUD" != "aws" ]; then
  echo "Usage: ./smoke-test.sh <vultr|aws> [--keep] [terraform args...]"
  exit 2
fi
shift

KEEP=0
TF_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *)      TF_ARGS+=("$arg") ;;
  esac
done

if [ -f .env ]; then set -a; source .env; set +a; fi

# The cloud under test wins over .env and terraform.tfvars alike, so pass it as
# a -var (highest precedence) rather than an environment variable.
HOSTNAME_VAR="weft-smoke"
TF_ARGS+=("-var=cloud=${CLOUD}" "-var=hostname=${HOSTNAME_VAR}")

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

say() { printf '\n=== %s ===\n' "$1"; }

cleanup() {
  local rc=$?
  if [ "$KEEP" = 1 ]; then
    say "Leaving the server up (--keep)"
    echo "Tear it down with:"
    echo "  terraform destroy -auto-approve ${TF_ARGS[*]}"
  else
    say "Destroying"
    terraform destroy -auto-approve "${TF_ARGS[@]}" >/dev/null 2>&1 \
      && echo "[ok] destroyed" \
      || { echo "[!!] destroy failed -- check the console, you may be paying for a server"; rc=1; }
  fi
  exit "$rc"
}

say "Applying to ${CLOUD}"
trap cleanup EXIT
if ! terraform apply -auto-approve "${TF_ARGS[@]}"; then
  echo "[!!] apply failed"
  exit 1
fi

IP="$(terraform output -raw server_ip)"
echo "[ok] server at ${IP}"

say "Waiting for SSH"
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "ops@${IP}" true 2>/dev/null; then
    echo "[ok] ssh as ops after ~$((i * 5))s"
    break
  fi
  if [ "$i" = 60 ]; then echo "[!!] no SSH after 5 minutes"; exit 1; fi
  sleep 5
done

say "Waiting for cloud-init"
ssh "${SSH_OPTS[@]}" "ops@${IP}" 'sudo cloud-init status --wait >/dev/null 2>&1; sudo cloud-init status' || true

say "Checks"
ssh "${SSH_OPTS[@]}" "ops@${IP}" 'bash -s' "$CLOUD" "$HOSTNAME_VAR" <<'REMOTE'
cloud="$1"; want_hostname="$2"
pass=0; fail=0

check() {
  local name="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"; fail=$((fail + 1))
  fi
}

check "cloud-init finished cleanly"   "sudo cloud-init status | grep -q 'status: done'"
check "hostname is ${want_hostname}"  "[ \"\$(hostname)\" = '${want_hostname}' ]"
check "logged in as ops"              "[ \"\$(whoami)\" = ops ]"
check "passwordless sudo"             "sudo -n true"

check "sshd: password auth off"       "sudo sshd -T | grep -qx 'passwordauthentication no'"
check "sshd: root login off"          "sudo sshd -T | grep -qx 'permitrootlogin no'"
check "sshd: X11 forwarding off"      "sudo sshd -T | grep -qx 'x11forwarding no'"
check "sshd: agent forwarding off"    "sudo sshd -T | grep -qx 'allowagentforwarding no'"
check "root authorized_keys gone"     "sudo test ! -s /root/.ssh/authorized_keys"

check "ufw active"                    "sudo ufw status verbose | grep -q '^Status: active'"
check "ufw denies incoming"           "sudo ufw status verbose | grep -q 'Default: deny (incoming)'"
check "ufw allows ssh"                "sudo ufw status | grep -q '22'"

for p in curl git jq rsync unzip ncdu lsof tcpdump atop dig; do
  check "package provides '$p'"       "command -v $p"
done

check "timezone is Europe/Berlin"     "[ \"\$(timedatectl show -p Timezone --value)\" = Europe/Berlin ]"
check "ntp enabled"                   "timedatectl show -p NTP --value | grep -qi yes"
check "swappiness is 1"               "[ \"\$(cat /proc/sys/vm/swappiness)\" = 1 ]"
check "unattended-upgrades masked"    "[ \"\$(systemctl is-enabled unattended-upgrades.service 2>&1)\" = masked ]"
check "unattended-upgrades removed"   "! dpkg -s unattended-upgrades 2>/dev/null | grep -q 'Status: install ok installed'"
check "apt update works"              "sudo apt-get -qq update"

if [ "$cloud" = "vultr" ]; then
  check "apt uses the cloud mirror"   "grep -rq clouds.archive.ubuntu.com /etc/apt/sources.list.d/ /etc/apt/sources.list"
else
  check "apt kept the ec2 mirror"     "grep -rq ec2.archive.ubuntu.com /etc/apt/sources.list.d/ /etc/apt/sources.list"
  check "amazon time sync configured" "grep -rq 169.254.169.123 /etc/systemd/timesyncd.conf.d/ /etc/chrony/ 2>/dev/null"
  check "IMDSv1 refused" \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://169.254.169.254/latest/meta-data/)\" = 401 ]"
  check "IMDSv2 works" \
    "t=\$(curl -sX PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' -m 5 http://169.254.169.254/latest/api/token) && curl -sf -H \"X-aws-ec2-metadata-token: \$t\" -m 5 http://169.254.169.254/latest/meta-data/instance-id"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
REMOTE

result=$?
if [ "$result" -eq 0 ]; then
  say "PASS (${CLOUD})"
else
  say "FAIL (${CLOUD}) -- see the checks above"
fi
exit "$result"
