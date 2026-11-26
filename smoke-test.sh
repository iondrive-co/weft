#!/usr/bin/env bash
# Provision a server, assert the box came up the way weft intends, then destroy
# it. Takes about four minutes and costs a couple of cents.
#
#   ./smoke-test.sh vultr
#   ./smoke-test.sh aws
#   ./smoke-test.sh aws --keep -var="region=eu-west-1"
#
# --keep leaves the server running (and tells you how to get rid of it).
# WEFT_SMOKE_TUNNEL=1 also gives the server a static IP, the cloud firewall and the tunnel egress, and checks them
# (a reserved IP is billed by the hour like the server, and released again by the destroy at the end).
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

# Always run in a dedicated smoke workspace so an active workspace's live server is never touched.
SMOKE_WS="${WEFT_SMOKE_WORKSPACE:-weft-smoke}"
if [ "${TF_WORKSPACE:-}" != "$SMOKE_WS" ]; then
  cur_ws="$(unset TF_WORKSPACE; terraform workspace show 2>/dev/null || echo default)"
  (
    unset TF_WORKSPACE
    terraform workspace select -or-create "$SMOKE_WS" >/dev/null || exit 1
    if [ "$cur_ws" != "$SMOKE_WS" ]; then
      terraform workspace select "$cur_ws" >/dev/null || exit 1
    fi
  ) || exit 1
  export TF_WORKSPACE="$SMOKE_WS"
fi

# The cloud under test wins over .env and terraform.tfvars alike, so pass it as
# a -var (highest precedence) rather than an environment variable.
HOSTNAME_VAR="weft-smoke"
TF_ARGS+=("-var=cloud=${CLOUD}" "-var=hostname=${HOSTNAME_VAR}")
# The checks below test these values, so ask for them whatever terraform.tfvars says.
TF_ARGS+=("-var=timezone=Europe/Berlin" "-var=ssh_tcp_forwarding=false")
TUNNEL="${WEFT_SMOKE_TUNNEL:-0}"
if [ "$TUNNEL" = 1 ]; then
  TF_ARGS+=("-var=tunnel=true" "-var=static_ip=true" "-var=vultr_firewall=true")
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10
          # cloud-init's firewall and sshd changes can drop a session mid-boot without closing it: give up on it.
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

say() { printf '\n=== %s ===\n' "$1"; }

cleanup() {
  local rc=$?
  if [ "$KEEP" = 1 ]; then
    say "Leaving the server up (--keep)"
    echo "Tear it down with:"
    echo "  TF_WORKSPACE=${SMOKE_WS} terraform destroy -auto-approve ${TF_ARGS[*]}"
  else
    say "Destroying"
    # A reserved IP can refuse deletion while its instance is still detaching, so try a few times.
    local try destroyed=0
    for try in 1 2 3; do
      if terraform destroy -auto-approve "${TF_ARGS[@]}" >/dev/null 2>&1; then destroyed=1; break; fi
      echo "[..] destroy attempt ${try} failed; retrying"
      sleep 15
    done
    [ "$destroyed" = 1 ] && echo "[ok] destroyed" \
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
if [ "$TUNNEL" = 1 ]; then
  STATIC="$(terraform output -raw static_ip 2>/dev/null)"
  [ -n "$STATIC" ] && [ "$STATIC" = "$IP" ] && echo "[ok] server_ip is the static IP" \
    || { echo "[!!] static_ip '${STATIC}' is not server_ip '${IP}'"; exit 1; }
fi

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
ssh "${SSH_OPTS[@]}" "ops@${IP}" 'bash -s' "$CLOUD" "$HOSTNAME_VAR" "$TUNNEL" "$IP" <<'REMOTE'
cloud="$1"; want_hostname="$2"; tunnel="$3"; want_ip="$4"
pass=0; fail=0

check() {
  local name="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"; fail=$((fail + 1))
  fi
}

check "cloud-init finished cleanly"   'status=$(sudo cloud-init status) && grep -qx "status: done" <<< "$status"'
check "hostname is ${want_hostname}"  "[ \"\$(hostname)\" = '${want_hostname}' ]"
check "logged in as ops"              "[ \"\$(whoami)\" = ops ]"
check "passwordless sudo"             "sudo -n true"

check "sshd: password auth off"       "sudo sshd -T | grep -qx 'passwordauthentication no'"
check "sshd: root login off"          "sudo sshd -T | grep -qx 'permitrootlogin no'"
check "sshd: X11 forwarding off"      "sudo sshd -T | grep -qx 'x11forwarding no'"
check "sshd: agent forwarding off"    "sudo sshd -T | grep -qx 'allowagentforwarding no'"
check "root authorized_keys gone"     "sudo test ! -s /root/.ssh/authorized_keys"
check "sshd: only ops may log in"     "sudo sshd -T | grep -qx 'allowusers ops'"
check "sshd: tcp forwarding off"      "sudo sshd -T | grep -qx 'allowtcpforwarding no'"
check "sshd: max 3 auth tries"        "sudo sshd -T | grep -qx 'maxauthtries 3'"
check "sshd: modern kex only"         "! sudo sshd -T | grep '^kexalgorithms' | grep -q 'sha1\\|group14\\|ecdh-sha2'"
check "sshd running"                  "systemctl is-active --quiet ssh || systemctl is-active --quiet sshd"
check "sysctl: no redirects"          "[ \"\$(sysctl -n net.ipv4.conf.all.accept_redirects)\" = 0 ]"
check "sysctl: kptr restricted"       "[ \"\$(sysctl -n kernel.kptr_restrict)\" = 2 ]"
check "sysctl: unprivileged bpf off"  "[ \"\$(sysctl -n kernel.unprivileged_bpf_disabled)\" != 0 ]"
check "ufw denies routed by default"  "sudo ufw status verbose | grep -q 'deny (routed)\\|disabled (routed)'"

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
check "apt update works"              "sudo apt-get -qq -o APT::Update::Error-Mode=any update"

if [ "$cloud" = "vultr" ]; then
  vultr_time_sync() {
    local attempt source
    for ((attempt=0; attempt<12; attempt++)); do
      source=
      if systemctl is-active --quiet chrony.service; then
        source=$(chronyc -N sources | awk '$1 == "^*" {print $2}')
      elif [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then
        source=$(timedatectl show-timesync -p ServerName --value)
      fi
      case "$source" in
        time.cloudflare.com|0.ubuntu.pool.ntp.org|1.ubuntu.pool.ntp.org) return 0 ;;
      esac
      sleep 5
    done
    return 1
  }
  check "clock synced to a configured Vultr NTP source" vultr_time_sync
  # Older Vultr images used the generic archive.ubuntu.com, which weft rewrites to the cloud mirror; newer ones ship
  # Vultr's own mirror. Either way, not the generic archive.
  check "apt uses a nearby mirror"    "! grep -rsqE --include='*.sources' --include='*.list' '//(us\\.)?archive\\.ubuntu\\.com' /etc/apt/sources.list.d/ /etc/apt/sources.list"
else
  check "apt kept the ec2 mirror"     "grep -rq ec2.archive.ubuntu.com /etc/apt/sources.list.d/ /etc/apt/sources.list"
  check "amazon time sync configured" "grep -rq 169.254.169.123 /etc/systemd/timesyncd.conf.d/ /etc/chrony/ 2>/dev/null"
  check "IMDSv1 refused" \
    "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://169.254.169.254/latest/meta-data/)\" = 401 ]"
  check "IMDSv2 works" \
    "t=\$(curl -sX PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' -m 5 http://169.254.169.254/latest/api/token) && curl -sf -H \"X-aws-ec2-metadata-token: \$t\" -m 5 http://169.254.169.254/latest/meta-data/instance-id"
fi

if [ "$tunnel" = 1 ]; then
  check "tunnel: egress public IP is the static IP" "[ \"\$(curl -4 -s -m 10 https://api.ipify.org)\" = '${want_ip}' ]"
  check "tunnel: wg0 up"                   "sudo wg show wg0 listen-port | grep -qx 51820"
  check "tunnel: server key private"       "[ \"\$(sudo stat -c %a /etc/wireguard/server.key)\" = 600 ]"
  check "tunnel: egress filter loaded"     "sudo nft list table inet weft_egress | grep -q masquerade"
  check "tunnel: forwarding on"            "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = 1 ]"
  check "tunnel: ufw allows the port"      "sudo ufw status | grep -q '51820/udp'"
  check "tunnel: ufw routes wg0 out"       "sudo ufw status | grep -q 'on wg0'"
  check "tunnel: weft-peer pubkey"         "sudo weft-peer pubkey | grep -Eq '^[A-Za-z0-9+/]{43}=\$'"
  key="$(wg genkey | wg pubkey)"
  check "tunnel: weft-peer add applies live" \
    "sudo weft-peer add smoke ${key} 10.77.0.9 && sudo wg show wg0 allowed-ips | grep -q '10.77.0.9/32'"
  check "tunnel: server key survives add"  "sudo wg show wg0 private-key | grep -q ."
  check "tunnel: weft-peer remove"         "sudo weft-peer remove smoke && ! sudo wg show wg0 peers | grep -q ."
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
