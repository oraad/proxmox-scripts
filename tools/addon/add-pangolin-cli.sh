#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/clients/install-client | Github: https://github.com/fosrl/cli
#
# Install Pangolin CLI (machine VPN client) on the Proxmox host or into an existing LXC.
# Unattended: var_target=host|<CTID> var_pangolin_endpoint=... var_client_id=... var_client_secret=...

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

function header_info() {
  clear
  cat <<"EOF"
    ____                   __            ________    ____
   / __ \____ _____  ____ _/ /___  ____  / ____/ /   /  _/
  / /_/ / __ `/ __ \/ __ `/ / __ \/ __ \/ /   / /    / /
 / ____/ /_/ / / / / /_/ / / /_/ / / / / /___/ /____/ /
/_/    \__,_/_/ /_/\__, /_/\____/_/ /_/\____/_____/___/
                  /____/

   Pangolin CLI (addon)

EOF
}

function msg_info() { echo -e " \e[1;36m➤\e[0m $1"; }
function msg_ok() { echo -e " \e[1;32m✔\e[0m $1"; }
function msg_error() { echo -e " \e[1;31m✖\e[0m $1"; }
function msg_warn() { echo -e " \e[1;33m!\e[0m $1"; }

header_info

if ! command -v pveversion &>/dev/null; then
  msg_error "This script must be run on the Proxmox VE host (not inside an LXC container)"
  exit 232
fi

# Install Pangolin CLI binary + service layout into the current environment (host or pct exec).
# Args: endpoint client_id client_secret
install_pangolin_cli_payload() {
  local endpoint="$1"
  local client_id="$2"
  local client_secret="$3"
  local arch version

  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache curl ca-certificates >/dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl &>/dev/null; then
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates >/dev/null
    fi
  fi

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7* | armhf) arch=arm32 ;;
    riscv64) arch=riscv64 ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      return 1
      ;;
    esac
  fi
  case "$arch" in
  armhf | armel) arch=arm32 ;;
  esac

  version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || {
    echo "Failed to resolve latest Pangolin CLI release" >&2
    return 1
  }

  curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
    -o /usr/local/bin/pangolin
  chmod 755 /usr/local/bin/pangolin
  echo "${version#v}" >/root/.pangolin-cli

  install -d -m 0755 /etc/pangolin-cli
  cat >/etc/pangolin-cli/client.env <<EOF
PANGOLIN_ENDPOINT=${endpoint}
PANGOLIN_CLIENT_ID=${client_id}
PANGOLIN_CLIENT_SECRET=${client_secret}
EOF
  chmod 600 /etc/pangolin-cli/client.env

  cat >/usr/local/bin/pangolin-cli-start <<'START'
#!/bin/sh
set -a
. /etc/pangolin-cli/client.env
set +a
exec /usr/local/bin/pangolin up \
  --id "$PANGOLIN_CLIENT_ID" \
  --secret "$PANGOLIN_CLIENT_SECRET" \
  --endpoint "$PANGOLIN_ENDPOINT" \
  --attach
START
  chmod 700 /usr/local/bin/pangolin-cli-start

  if [[ -f /etc/alpine-release ]]; then
    cat >/etc/init.d/pangolin-cli <<'INIT'
#!/sbin/openrc-run

name="pangolin-cli"
description="Pangolin CLI machine client"
command="/usr/local/bin/pangolin-cli-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/pangolin-cli.log"
error_log="/var/log/pangolin-cli.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/pangolin-cli
    rc-update add pangolin-cli default 2>/dev/null || true
    rc-service pangolin-cli restart 2>/dev/null || rc-service pangolin-cli start
  else
    cat >/etc/systemd/system/pangolin-cli.service <<'UNIT'
[Unit]
Description=Pangolin CLI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/pangolin-cli-start
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pangolin-cli
    systemctl restart pangolin-cli
  fi

  cat >/usr/bin/update-pangolin-cli <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f /etc/pangolin-cli/client.env ]]; then
  echo "No Pangolin CLI installation found (/etc/pangolin-cli/client.env missing)" >&2
  exit 1
fi
arch="$(dpkg --print-architecture 2>/dev/null || true)"
if [[ -z "$arch" ]]; then
  case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  armv7*|armhf) arch=arm32 ;;
  riscv64) arch=riscv64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi
case "$arch" in armhf|armel) arch=arm32 ;; esac
version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
[[ -n "$version" ]] || { echo "Failed to resolve latest Pangolin CLI release" >&2; exit 1; }
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-cli stop 2>/dev/null || true
else
  systemctl stop pangolin-cli 2>/dev/null || true
fi
curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
  -o /usr/local/bin/pangolin
chmod 755 /usr/local/bin/pangolin
echo "${version#v}" >/root/.pangolin-cli
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-cli start
else
  systemctl start pangolin-cli
fi
echo "Updated Pangolin CLI to ${version}"
UPD
  chmod +x /usr/bin/update-pangolin-cli
}

# Ensure /dev/net/tun is available inside an LXC (required for Pangolin CLI VPN).
# Returns 0 if conf was unchanged; non-zero if conf changed (caller should restart CT).
ensure_lxc_tun() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  local changed=0

  if [[ ! -c /dev/net/tun ]]; then
    msg_info "Loading tun module on the Proxmox host"
    modprobe tun || {
      msg_error "Failed to load tun module on the host"
      exit 1
    }
  fi

  if ! grep -qE 'lxc\.cgroup2\.devices\.allow:[[:space:]]*c[[:space:]]+10:200' "$conf" 2>/dev/null; then
    echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >>"$conf"
    changed=1
  fi
  if ! grep -qE 'lxc\.mount\.entry:[[:space:]].*dev/net/tun' "$conf" 2>/dev/null; then
    echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >>"$conf"
    changed=1
  fi

  return "$changed"
}

wait_ct_running() {
  local ctid="$1"
  while [[ "$(pct status "$ctid" | awk '{print $2}')" != "running" ]]; do
    sleep 2
  done
}

prompt_credentials() {
  if [[ -n "${var_pangolin_endpoint:-}" && -n "${var_client_id:-}" && -n "${var_client_secret:-}" ]]; then
    PANGOLIN_ENDPOINT="$var_pangolin_endpoint"
    CLIENT_ID="$var_client_id"
    CLIENT_SECRET="$var_client_secret"
    return 0
  fi

  read -rp "Pangolin endpoint [https://app.pangolin.net]: " PANGOLIN_ENDPOINT
  PANGOLIN_ENDPOINT="${PANGOLIN_ENDPOINT:-https://app.pangolin.net}"
  read -rp "Machine client ID (from Pangolin dashboard): " CLIENT_ID
  read -rsp "Machine client secret: " CLIENT_SECRET
  echo
  if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" || -z "${PANGOLIN_ENDPOINT}" ]]; then
    msg_error "Pangolin endpoint, client ID, and client secret are required"
    exit 1
  fi
}

select_target() {
  if [[ -n "${var_target:-}" ]]; then
    TARGET="$var_target"
    return 0
  fi

  TARGET=$(whiptail --backtitle "Proxmox Custom Scripts" --title "Pangolin CLI Addon" --menu \
    "\nInstall Pangolin CLI on:\n" 14 60 2 \
    "host" "This Proxmox host" \
    "lxc" "An existing LXC container" \
    3>&1 1>&2 2>&3) || exit 0

  if [[ "$TARGET" == "lxc" ]]; then
    local NODE MSG_MAX_LENGTH=0
    local -a CTID_MENU=()
    NODE=$(hostname)
    while read -r line; do
      local TAG ITEM OFFSET=2
      TAG=$(echo "$line" | awk '{print $1}')
      ITEM=$(echo "$line" | awk '{print substr($0,36)}')
      ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
      CTID_MENU+=("$TAG" "$ITEM" "OFF")
    done < <(pct list | awk 'NR>1')

    if [[ ${#CTID_MENU[@]} -eq 0 ]]; then
      msg_error "No LXC containers found"
      exit 1
    fi

    TARGET=$(whiptail --backtitle "Proxmox Custom Scripts" --title "Containers on $NODE" --radiolist \
      "\nSelect a container to add Pangolin CLI to:\n" \
      16 $((MSG_MAX_LENGTH + 23)) 6 \
      "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit 0
  fi
}

if [[ -z "${var_target:-}" ]]; then
  while true; do
    read -rp "This will install Pangolin CLI on the Proxmox host or an existing LXC. Proceed (y/n)? " yn
    case "$yn" in
    [Yy]*) break ;;
    [Nn]*) exit 0 ;;
    *) echo "Please answer yes or no." ;;
    esac
  done
fi

header_info
select_target
prompt_credentials

if [[ "$TARGET" == "host" ]]; then
  msg_warn "Installing on the Proxmox host — the entire host joins the Pangolin network."
  msg_info "Installing Pangolin CLI on the Proxmox host"
  install_pangolin_cli_payload "$PANGOLIN_ENDPOINT" "$CLIENT_ID" "$CLIENT_SECRET"
  msg_ok "Installed Pangolin CLI on the Proxmox host"
  msg_info "Service: systemctl status pangolin-cli"
  msg_info "Manual update: update-pangolin-cli"
  exit 0
fi

# LXC target
CTID="$TARGET"
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  msg_error "Invalid container ID: $CTID"
  exit 1
fi

LXC_STATUS=$(pct status "$CTID" | awk '{print $2}')
if [[ "$LXC_STATUS" != "running" ]]; then
  msg_info "Starting container $CTID"
  pct start "$CTID"
  wait_ct_running "$CTID"
  msg_ok "Container $CTID is running"
fi

DISTRO=$(pct exec "$CTID" -- sh -c '. /etc/os-release 2>/dev/null; echo "${ID:-unknown}"')
case "$DISTRO" in
debian | ubuntu | alpine) ;;
*)
  msg_error "Unsupported OS in CT $CTID: $DISTRO (need debian, ubuntu, or alpine)"
  exit 238
  ;;
esac

msg_info "Configuring TUN device passthrough for CT $CTID"
if ensure_lxc_tun "$CTID"; then
  : # conf unchanged
else
  msg_info "Restarting CT $CTID to apply TUN configuration"
  pct stop "$CTID"
  pct start "$CTID"
  wait_ct_running "$CTID"
  msg_ok "Container $CTID is running with TUN"
fi

msg_info "Installing Pangolin CLI in CT $CTID"
pct exec "$CTID" -- env \
  PANGOLIN_ENDPOINT="$PANGOLIN_ENDPOINT" \
  CLIENT_ID="$CLIENT_ID" \
  CLIENT_SECRET="$CLIENT_SECRET" \
  bash -s <<'REMOTE'
set -euo pipefail
install_pangolin_cli_payload() {
  local endpoint="$1"
  local client_id="$2"
  local client_secret="$3"
  local arch version

  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache curl ca-certificates >/dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl &>/dev/null; then
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates >/dev/null
    fi
  fi

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7*|armhf) arch=arm32 ;;
    riscv64) arch=riscv64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
  fi
  case "$arch" in armhf|armel) arch=arm32 ;; esac

  version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || { echo "Failed to resolve latest Pangolin CLI release" >&2; return 1; }

  curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
    -o /usr/local/bin/pangolin
  chmod 755 /usr/local/bin/pangolin
  echo "${version#v}" >/root/.pangolin-cli

  install -d -m 0755 /etc/pangolin-cli
  cat >/etc/pangolin-cli/client.env <<EOF
PANGOLIN_ENDPOINT=${endpoint}
PANGOLIN_CLIENT_ID=${client_id}
PANGOLIN_CLIENT_SECRET=${client_secret}
EOF
  chmod 600 /etc/pangolin-cli/client.env

  cat >/usr/local/bin/pangolin-cli-start <<'START'
#!/bin/sh
set -a
. /etc/pangolin-cli/client.env
set +a
exec /usr/local/bin/pangolin up \
  --id "$PANGOLIN_CLIENT_ID" \
  --secret "$PANGOLIN_CLIENT_SECRET" \
  --endpoint "$PANGOLIN_ENDPOINT" \
  --attach
START
  chmod 700 /usr/local/bin/pangolin-cli-start

  if [[ -f /etc/alpine-release ]]; then
    cat >/etc/init.d/pangolin-cli <<'INIT'
#!/sbin/openrc-run

name="pangolin-cli"
description="Pangolin CLI machine client"
command="/usr/local/bin/pangolin-cli-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/pangolin-cli.log"
error_log="/var/log/pangolin-cli.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/pangolin-cli
    rc-update add pangolin-cli default 2>/dev/null || true
    rc-service pangolin-cli restart 2>/dev/null || rc-service pangolin-cli start
  else
    cat >/etc/systemd/system/pangolin-cli.service <<'UNIT'
[Unit]
Description=Pangolin CLI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/pangolin-cli-start
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pangolin-cli
    systemctl restart pangolin-cli
  fi

  cat >/usr/bin/update-pangolin-cli <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f /etc/pangolin-cli/client.env ]]; then
  echo "No Pangolin CLI installation found (/etc/pangolin-cli/client.env missing)" >&2
  exit 1
fi
arch="$(dpkg --print-architecture 2>/dev/null || true)"
if [[ -z "$arch" ]]; then
  case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  armv7*|armhf) arch=arm32 ;;
  riscv64) arch=riscv64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi
case "$arch" in armhf|armel) arch=arm32 ;; esac
version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
[[ -n "$version" ]] || { echo "Failed to resolve latest Pangolin CLI release" >&2; exit 1; }
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-cli stop 2>/dev/null || true
else
  systemctl stop pangolin-cli 2>/dev/null || true
fi
curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
  -o /usr/local/bin/pangolin
chmod 755 /usr/local/bin/pangolin
echo "${version#v}" >/root/.pangolin-cli
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-cli start
else
  systemctl start pangolin-cli
fi
echo "Updated Pangolin CLI to ${version}"
UPD
  chmod +x /usr/bin/update-pangolin-cli
}
install_pangolin_cli_payload "$PANGOLIN_ENDPOINT" "$CLIENT_ID" "$CLIENT_SECRET"
REMOTE

CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"
TAGS=$(awk -F': ' '/^tags:/ {print $2}' "$CTID_CONFIG_PATH" 2>/dev/null || true)
if [[ -n "$TAGS" ]]; then
  if [[ "$TAGS" != *pangolin-cli* ]]; then
    pct set "$CTID" -tags "${TAGS};pangolin-cli"
  fi
else
  pct set "$CTID" -tags "pangolin-cli"
fi

msg_ok "Installed Pangolin CLI on CT $CTID"
msg_info "Manual update: pct exec $CTID -- update-pangolin-cli"
msg_info "Service status: pct exec $CTID -- systemctl status pangolin-cli"
