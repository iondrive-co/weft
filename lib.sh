#!/usr/bin/env bash
# Shared helpers for setup.sh / weft.sh. Not meant to be run directly.

# --- output ---------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_OK=$'\033[32m'; C_BAD=$'\033[31m'
  C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_DIM=""; C_B=""; C_OK=""; C_BAD=""; C_WARN=""; C_OFF=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_OFF" "$C_B" "$1" "$C_OFF"; }
ok()    { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }
bad()   { printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$1"; }
warn()  { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
info()  { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

die() { bad "$1"; exit 1; }

# --- prompts --------------------------------------------------------------
#
# These write into a variable you name rather than echoing, so that hitting
# Ctrl-D can abort the whole script instead of quietly selecting a default.

need_tty() {
  [ -t 0 ] || die "Weft's setup is interactive; run it from a terminal."
}

# ask <var> <prompt> [default]
ask() {
  local __var="$1" prompt="$2" default="${3:-}" reply=""
  if [ -n "$default" ]; then
    read -rp "  ${prompt} [${default}]: " reply || die "Cancelled."
  else
    read -rp "  ${prompt}: " reply || die "Cancelled."
  fi
  printf -v "$__var" '%s' "${reply:-$default}"
}

# ask_secret <var> <prompt>   (not echoed)
ask_secret() {
  local __var="$1" reply=""
  read -rsp "  ${2}: " reply || die "Cancelled."
  printf '\n'
  printf -v "$__var" '%s' "$reply"
}

# confirm <prompt> [Y|N]  -> exit status
confirm() {
  local prompt="$1" default="${2:-Y}" reply=""
  local hint="[Y/n]"; [ "$default" = "N" ] && hint="[y/N]"
  read -rp "  ${prompt} ${hint} " reply || die "Cancelled."
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# pick <var> <prompt> <value|label>...
pick() {
  local __var="$1" prompt="$2"; shift 2
  local n=$# i=1 pick_n="" custom=""
  local item
  for item in "$@"; do
    printf '   %2d) %s\n' "$i" "${item#*|}"
    i=$((i + 1))
  done
  printf '   %2d) something else (type it in)\n' "$i"
  while :; do
    read -rp "  ${prompt} [1]: " pick_n || die "Cancelled."
    pick_n="${pick_n:-1}"
    case "$pick_n" in
      *[!0-9]*|'') warn "Type one of the numbers above." ; continue ;;
    esac
    if [ "$pick_n" -ge 1 ] && [ "$pick_n" -le "$i" ]; then break; fi
    warn "Pick a number between 1 and ${i}."
  done

  if [ "$pick_n" = "$i" ]; then
    while [ -z "$custom" ]; do
      read -rp "  Value: " custom || die "Cancelled."
    done
    printf -v "$__var" '%s' "$custom"
    return
  fi
  eval "item=\${$pick_n}"
  printf -v "$__var" '%s' "${item%%|*}"
}

# ask_until <var> <prompt> <default> <regex> <complaint>
ask_until() {
  local __var="$1" prompt="$2" default="$3" regex="$4" complaint="$5" value=""
  while :; do
    ask value "$prompt" "$default"
    if [[ "$value" =~ $regex ]]; then
      printf -v "$__var" '%s' "$value"
      return
    fi
    warn "$complaint"
  done
}

# --- browser and clipboard ------------------------------------------------

have_display() {
  case "$OSTYPE" in
    darwin*) return 0 ;;
    *) [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ -n "${WSL_DISTRO_NAME:-}" ] ;;
  esac
}

# open_url <url> [what]
open_url() {
  local url="$1" what="${2:-page}"
  if have_display; then
    local opener=""
    for candidate in "${BROWSER:-}" xdg-open open wslview; do
      [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 && { opener="$candidate"; break; }
    done
    if [ -n "$opener" ]; then
      ("$opener" "$url" >/dev/null 2>&1 &) 
      ok "Opened the ${what} in your browser"
      info "$url"
      return 0
    fi
  fi
  warn "Open this ${what} yourself:"
  info "$url"
}

# clip <text> [label]
clip() {
  local text="$1" label="${2:-value}"
  local tool=""
  for candidate in wl-copy xclip xsel pbcopy; do
    command -v "$candidate" >/dev/null 2>&1 && { tool="$candidate"; break; }
  done
  case "$tool" in
    wl-copy) printf '%s' "$text" | wl-copy 2>/dev/null ;;
    xclip)   printf '%s' "$text" | xclip -selection clipboard 2>/dev/null ;;
    xsel)    printf '%s' "$text" | xsel -ib 2>/dev/null ;;
    pbcopy)  printf '%s' "$text" | pbcopy 2>/dev/null ;;
    *)       return 1 ;;
  esac
  ok "Copied the ${label} to your clipboard"
}

my_ip() {
  curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 10 https://api.myip.com 2>/dev/null | jq -r '.ip' 2>/dev/null \
    || true
}

# --- .env and tfvars ------------------------------------------------------

env_get() {
  [ -f .env ] || return 0
  grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- || true
}

env_set() {
  local key="$1" value="$2" tmp
  touch .env; chmod 600 .env
  tmp="$(mktemp)"
  grep -v "^${key}=" .env >"$tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >.env
  rm -f "$tmp"
  chmod 600 .env
}

env_unset() {
  local key="$1" tmp
  [ -f .env ] || return 0
  tmp="$(mktemp)"
  grep -v "^${key}=" .env >"$tmp" || true
  cat "$tmp" >.env
  rm -f "$tmp"
  chmod 600 .env
}

env_load() {
  [ -f .env ] || return 0
  set -a; source ./.env; set +a
}

# tfvars_set <key> <hcl-value>   e.g. tfvars_set region '"ams"'
tfvars_set() {
  local key="$1" value="$2" tmp
  touch terraform.tfvars
  tmp="$(mktemp)"
  grep -v "^${key} *=" terraform.tfvars >"$tmp" || true
  printf '%s = %s\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >terraform.tfvars
  rm -f "$tmp"
}
