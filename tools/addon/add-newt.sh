#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/newt
#
# Install Pangolin Newt on the Proxmox host or into an existing LXC.
# Unattended: var_target=host|<CTID> var_pangolin_endpoint=... var_newt_id=... var_newt_secret=...

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

function header_info() {
  clear
  cat <<"EOF"
    _   __               __
   / | / /__ _      __  / /_
  /  |/ / _ \ | /| / / / __/
 / /|  /  __/ |/ |/ / / /_
/_/ |_/\___/|__/|__/  \__/

   Pangolin Newt (addon)

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

# Install Newt binary + service layout into the current environment (host or pct exec).
# Args: endpoint id secret update_cmd_mode (host|lxc)
install_newt_payload() {
  local endpoint="$1"
  local newt_id="$2"
  local newt_secret="$3"
  local update_mode="$4"
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

  version="$(curl -fsSL https://api.github.com/repos/fosrl/newt/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || {
    echo "Failed to resolve latest Newt release" >&2
    return 1
  }

  curl -fsSL "https://github.com/fosrl/newt/releases/download/${version}/newt_linux_${arch}" \
    -o /usr/local/bin/newt
  chmod 755 /usr/local/bin/newt
  # Version file for check_for_gh_release / dry-run compatibility
  echo "${version#v}" >/root/.newt

  install -d -m 0755 /etc/newt
  cat >/etc/newt/newt.env <<EOF
NEWT_ID=${newt_id}
NEWT_SECRET=${newt_secret}
PANGOLIN_ENDPOINT=${endpoint}
EOF
  chmod 600 /etc/newt/newt.env

  if [[ -f /etc/alpine-release ]]; then
    cat >/usr/local/bin/newt-start <<'START'
#!/bin/sh
set -a
. /etc/newt/newt.env
set +a
exec /usr/local/bin/newt
START
    chmod 700 /usr/local/bin/newt-start

    cat >/etc/init.d/newt <<'INIT'
#!/sbin/openrc-run

name="newt"
description="Pangolin Newt tunnel agent"
command="/usr/local/bin/newt-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/newt.log"
error_log="/var/log/newt.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/newt
    rc-update add newt default 2>/dev/null || true
    rc-service newt restart 2>/dev/null || rc-service newt start
  else
    cat >/etc/systemd/system/newt.service <<'UNIT'
[Unit]
Description=Pangolin Newt
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/newt/newt.env
ExecStart=/usr/local/bin/newt
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now newt
    systemctl restart newt
  fi

  if [[ "$update_mode" == "host" ]]; then
    cat >/usr/bin/update-newt <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f /etc/newt/newt.env ]]; then
  echo "No Pangolin Newt installation found (/etc/newt/newt.env missing)" >&2
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
version="$(curl -fsSL https://api.github.com/repos/fosrl/newt/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
systemctl stop newt 2>/dev/null || true
curl -fsSL "https://github.com/fosrl/newt/releases/download/${version}/newt_linux_${arch}" -o /usr/local/bin/newt
chmod 755 /usr/local/bin/newt
echo "${version#v}" >/root/.newt
systemctl start newt
echo "Updated Newt to ${version}"
UPD
  else
    cat >/usr/bin/update-newt <<EOF
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/newt.sh)"
EOF
  fi
  chmod +x /usr/bin/update-newt
}

prompt_credentials() {
  if [[ -n "${var_pangolin_endpoint:-}" && -n "${var_newt_id:-}" && -n "${var_newt_secret:-}" ]]; then
    PANGOLIN_ENDPOINT="$var_pangolin_endpoint"
    NEWT_ID="$var_newt_id"
    NEWT_SECRET="$var_newt_secret"
    return 0
  fi

  read -rp "Pangolin endpoint [https://app.pangolin.net]: " PANGOLIN_ENDPOINT
  PANGOLIN_ENDPOINT="${PANGOLIN_ENDPOINT:-https://app.pangolin.net}"
  read -rp "Newt ID (from Pangolin site config): " NEWT_ID
  read -rsp "Newt secret: " NEWT_SECRET
  echo
  if [[ -z "${NEWT_ID}" || -z "${NEWT_SECRET}" || -z "${PANGOLIN_ENDPOINT}" ]]; then
    msg_error "Pangolin endpoint, Newt ID, and Newt secret are required"
    exit 1
  fi
}

select_target() {
  if [[ -n "${var_target:-}" ]]; then
    TARGET="$var_target"
    return 0
  fi

  TARGET=$(whiptail --backtitle "Proxmox Custom Scripts" --title "Pangolin Newt Addon" --menu \
    "\nInstall Newt on:\n" 14 60 2 \
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
      "\nSelect a container to add Newt to:\n" \
      16 $((MSG_MAX_LENGTH + 23)) 6 \
      "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit 0
  fi
}

if [[ -z "${var_target:-}" ]]; then
  while true; do
    read -rp "This will install Pangolin Newt on the Proxmox host or an existing LXC. Proceed (y/n)? " yn
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
  msg_warn "Installing on the Proxmox host — Newt can reach everything the host can."
  msg_info "Installing Pangolin Newt on the Proxmox host"
  # Export payload function and run in a subshell with credentials
  install_newt_payload "$PANGOLIN_ENDPOINT" "$NEWT_ID" "$NEWT_SECRET" "host"
  msg_ok "Installed Pangolin Newt on the Proxmox host"
  msg_info "Service: systemctl status newt"
  msg_info "Manual update: update-newt"
  msg_info "Primary updates: enable Automatic Site Updates in the Pangolin dashboard (Newt ≥ 1.13.0)"
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
  while [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; do
    sleep 2
  done
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

msg_info "Installing Pangolin Newt in CT $CTID"
# Serialize install function + credentials into the container
pct exec "$CTID" -- env \
  REPO_RAW="$REPO_RAW" \
  PANGOLIN_ENDPOINT="$PANGOLIN_ENDPOINT" \
  NEWT_ID="$NEWT_ID" \
  NEWT_SECRET="$NEWT_SECRET" \
  bash -s <<'REMOTE'
set -euo pipefail
install_newt_payload() {
  local endpoint="$1"
  local newt_id="$2"
  local newt_secret="$3"
  local update_mode="$4"
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

  version="$(curl -fsSL https://api.github.com/repos/fosrl/newt/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || { echo "Failed to resolve latest Newt release" >&2; return 1; }

  curl -fsSL "https://github.com/fosrl/newt/releases/download/${version}/newt_linux_${arch}" \
    -o /usr/local/bin/newt
  chmod 755 /usr/local/bin/newt
  echo "${version#v}" >/root/.newt

  install -d -m 0755 /etc/newt
  cat >/etc/newt/newt.env <<EOF
NEWT_ID=${newt_id}
NEWT_SECRET=${newt_secret}
PANGOLIN_ENDPOINT=${endpoint}
EOF
  chmod 600 /etc/newt/newt.env

  if [[ -f /etc/alpine-release ]]; then
    cat >/usr/local/bin/newt-start <<'START'
#!/bin/sh
set -a
. /etc/newt/newt.env
set +a
exec /usr/local/bin/newt
START
    chmod 700 /usr/local/bin/newt-start

    cat >/etc/init.d/newt <<'INIT'
#!/sbin/openrc-run

name="newt"
description="Pangolin Newt tunnel agent"
command="/usr/local/bin/newt-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/newt.log"
error_log="/var/log/newt.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/newt
    rc-update add newt default 2>/dev/null || true
    rc-service newt restart 2>/dev/null || rc-service newt start
  else
    cat >/etc/systemd/system/newt.service <<'UNIT'
[Unit]
Description=Pangolin Newt
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/newt/newt.env
ExecStart=/usr/local/bin/newt
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now newt
    systemctl restart newt
  fi

  cat >/usr/bin/update-newt <<EOF
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/newt.sh)"
EOF
  chmod +x /usr/bin/update-newt
}
install_newt_payload "$PANGOLIN_ENDPOINT" "$NEWT_ID" "$NEWT_SECRET" "lxc"
REMOTE

CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"
TAGS=$(awk -F': ' '/^tags:/ {print $2}' "$CTID_CONFIG_PATH" 2>/dev/null || true)
if [[ -n "$TAGS" ]]; then
  if [[ "$TAGS" != *newt* ]]; then
    pct set "$CTID" -tags "${TAGS};newt"
  fi
else
  pct set "$CTID" -tags "newt"
fi

msg_ok "Installed Pangolin Newt on CT $CTID"
msg_info "Manual update: pct exec $CTID -- update-newt"
msg_info "Primary updates: enable Automatic Site Updates in the Pangolin dashboard (Newt ≥ 1.13.0)"
