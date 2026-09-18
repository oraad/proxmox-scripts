#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/clients/install-client |
#         https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/cli
#
# Unified Pangolin addon. Installs the official Pangolin CLI binary once and
# enables Site mode (`pangolin up site` — the Newt replacement, userspace
# WireGuard, no TUN) and/or Machine Client mode (`pangolin up --id ... --attach`,
# TUN-based VPN) on the Proxmox host or into an existing LXC.
#
# Existing standalone Newt installs are detected (site mode) and migrated in
# place, reusing the same site ID/secret/endpoint (no new credentials needed).
#
# Unattended:
#   var_mode=site|client|both          (interactive menu when unset)
#   var_target=host|<CTID>
#   Site/both: var_pangolin_endpoint=... var_site_id=... var_site_secret=...
#   Client/both: var_client_id=... var_client_secret=...
# Legacy aliases (site mode): var_newt_id / var_newt_secret

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

function header_info() {
  clear
  cat <<"EOF"
    _   __               __   _ __  _
   / | / /__ _      __  / /_ (_) /_(_)___  ____ _
  /  |/ / _ \ | /| / / / __// / __/ / __ \/ __ `/
 / /| /  __/ |/ |/ / / /_ / / /_/ / / / / /_/ /
/_/ |_/\___/|__/|__/  \__//_/\__/_/_/ /_/\__, /
                                        /____/
   Pangolin Addon (CLI)

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

# Stop the old standalone Newt service and remove its binary/env/updater so the
# CLI site mode takes over cleanly. Safe on Alpine (keeps the `newt` dialog
# package; only /usr/local/bin/newt is the Pangolin binary).
remove_legacy_newt() {
  if [[ -f /etc/alpine-release ]]; then
    rc-service newt stop 2>/dev/null || true
    rc-update del newt default >/dev/null 2>&1 || true
    rm -f /etc/init.d/newt
  else
    systemctl disable --now newt >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/newt.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/newt /usr/local/bin/newt-start \
    /etc/newt/newt.env /usr/bin/update-newt /root/.newt
  rmdir /etc/newt >/dev/null 2>&1 || true
}

prepare_env() {
  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache curl ca-certificates >/dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl &>/dev/null; then
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates >/dev/null
    fi
  fi
}

cli_arch() {
  local arch
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
  echo "$arch"
}

resolve_cli_version() {
  local version
  version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || {
    echo "Failed to resolve latest Pangolin CLI release" >&2
    return 1
  }
  echo "$version"
}

# Shared binary install — idempotent (skips when the current version marker is
# already present so Site + Client mode never download twice).
install_cli_binary() {
  local arch version current
  arch="$(cli_arch)"
  version="$(resolve_cli_version)"
  current="$(cat /root/.pangolin-cli 2>/dev/null || true)"
  if [[ "${current:-}" == "${version#v}" && -x /usr/local/bin/pangolin ]]; then
    msg_info "Pangolin CLI ${version} already installed"
    return 0
  fi
  msg_info "Installing Pangolin CLI ${version}"
  curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
    -o /usr/local/bin/pangolin
  chmod 755 /usr/local/bin/pangolin
  echo "${version#v}" >/root/.pangolin-cli
}

# Site mode — `pangolin up site` (Newt embedded in the CLI).
# Args: endpoint site_id site_secret
install_site_service() {
  local endpoint="$1"
  local site_id="$2"
  local site_secret="$3"

  install_cli_binary

  install -d -m 0755 /etc/pangolin
  cat >/etc/pangolin/pangolin-site.env <<EOF
SITE_ID=${site_id}
SITE_SECRET=${site_secret}
PANGOLIN_ENDPOINT=${endpoint}
EOF
  chmod 600 /etc/pangolin/pangolin-site.env

  cat >/usr/local/bin/pangolin-site-start <<'START'
#!/bin/sh
set -a
if [ -f /etc/pangolin/pangolin-site.env ]; then
  . /etc/pangolin/pangolin-site.env
fi
# `pangolin up site` is Newt embedded in the CLI and honors the same NEWT_*
# vars as the standalone binary, alongside the SITE_* aliases. Export both.
export NEWT_ID="${SITE_ID:-${NEWT_ID:-}}"
export NEWT_SECRET="${SITE_SECRET:-${NEWT_SECRET:-}}"
set +a
exec /usr/local/bin/pangolin up site
START
  chmod 700 /usr/local/bin/pangolin-site-start

  remove_legacy_newt

  if [[ -f /etc/alpine-release ]]; then
    cat >/etc/init.d/pangolin-site <<'INIT'
#!/sbin/openrc-run

name="pangolin-site"
description="Pangolin Site connector (CLI)"
command="/usr/local/bin/pangolin-site-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/pangolin-site.log"
error_log="/var/log/pangolin-site.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/pangolin-site
    rc-update add pangolin-site default 2>/dev/null || true
    rc-service pangolin-site restart 2>/dev/null || rc-service pangolin-site start
  else
    cat >/etc/systemd/system/pangolin-site.service <<'UNIT'
[Unit]
Description=Pangolin Site (CLI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/pangolin/pangolin-site.env
ExecStart=/usr/local/bin/pangolin-site-start
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pangolin-site
    systemctl restart pangolin-site
  fi

  cat >/usr/bin/update-pangolin-site <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f /etc/pangolin/pangolin-site.env ]]; then
  echo "No Pangolin Site installation found (/etc/pangolin/pangolin-site.env missing)" >&2
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
  rc-service pangolin-site stop 2>/dev/null || true
else
  systemctl stop pangolin-site 2>/dev/null || true
fi
curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
  -o /usr/local/bin/pangolin
chmod 755 /usr/local/bin/pangolin
echo "${version#v}" >/root/.pangolin-cli
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-site start
else
  systemctl start pangolin-site
fi
echo "Updated Pangolin CLI to ${version}"
UPD
  chmod +x /usr/bin/update-pangolin-site
}

# Machine client mode — `pangolin up --id ... --secret ... --endpoint ... --attach`.
# Args: endpoint client_id client_secret
install_client_service() {
  local endpoint="$1"
  local client_id="$2"
  local client_secret="$3"

  install_cli_binary

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

select_mode() {
  SITE_ENABLED=0
  CLIENT_ENABLED=0

  if [[ -n "${var_mode:-}" ]]; then
    case "$var_mode" in
    site) SITE_ENABLED=1 ;;
    client) CLIENT_ENABLED=1 ;;
    both) SITE_ENABLED=1 && CLIENT_ENABLED=1 ;;
    *)
      msg_error "Invalid var_mode: $var_mode (site|client|both)"
      exit 1
      ;;
    esac
    MODE="$var_mode"
    return 0
  fi

  local MODES
  MODES=$(whiptail --backtitle "Proxmox Custom Scripts" --title "Pangolin Addon" --checklist \
    "\nSelect Pangolin CLI components to install (Space to toggle):\n" 12 64 2 \
    "site" "Site tunnel - Newt replacement (userspace WG)" ON \
    "client" "Machine client - VPN (needs TUN)" OFF \
    3>&1 1>&2 2>&3) || exit 0
  MODES="${MODES//\"/}"
  case "$MODES" in
  *site*) SITE_ENABLED=1 ;;
  esac
  case "$MODES" in
  *client*) CLIENT_ENABLED=1 ;;
  esac
  if [[ "$SITE_ENABLED" == "0" && "$CLIENT_ENABLED" == "0" ]]; then
    msg_error "No components selected — nothing to install"
    exit 0
  fi
}

select_target() {
  if [[ -n "${var_target:-}" ]]; then
    TARGET="$var_target"
    return 0
  fi

  TARGET=$(whiptail --backtitle "Proxmox Custom Scripts" --title "Pangolin Addon" --menu \
    "\nInstall Pangolin CLI components on:\n" 14 60 2 \
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
      "\nSelect a container to add Pangolin CLI components to:\n" \
      16 $((MSG_MAX_LENGTH + 23)) 6 \
      "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit 0
  fi
}

prompt_endpoint() {
  if [[ -n "${PANGOLIN_ENDPOINT:-}" ]]; then
    return 0
  fi
  if [[ -n "${var_pangolin_endpoint:-}" ]]; then
    PANGOLIN_ENDPOINT="$var_pangolin_endpoint"
    return 0
  fi
  read -rp "Pangolin endpoint [https://app.pangolin.net]: " PANGOLIN_ENDPOINT
  PANGOLIN_ENDPOINT="${PANGOLIN_ENDPOINT:-https://app.pangolin.net}"
}

prompt_site_credentials() {
  local var_id="${var_site_id:-${var_newt_id:-}}"
  local var_secret="${var_site_secret:-${var_newt_secret:-}}"

  if [[ -n "$var_id" && -n "$var_secret" ]]; then
    SITE_ID="$var_id"
    SITE_SECRET="$var_secret"
    return 0
  fi

  if [[ -n "${MIGRATE_FROM_NEWT:-}" && -n "${LEGACY_NEWT_ID:-}" && -n "${LEGACY_NEWT_SECRET:-}" && -n "${LEGACY_ENDPOINT:-}" ]]; then
    SITE_ID="$LEGACY_NEWT_ID"
    SITE_SECRET="$LEGACY_NEWT_SECRET"
    PANGOLIN_ENDPOINT="${PANGOLIN_ENDPOINT:-$LEGACY_ENDPOINT}"
    msg_info "Reusing credentials from the existing Newt site ${SITE_ID}"
    return 0
  fi

  prompt_endpoint
  read -rp "Site ID (from Pangolin site config): " SITE_ID
  read -rsp "Site secret: " SITE_SECRET
  echo
  if [[ -z "${SITE_ID}" || -z "${SITE_SECRET}" || -z "${PANGOLIN_ENDPOINT}" ]]; then
    msg_error "Pangolin endpoint, Site ID, and site secret are required"
    exit 1
  fi
}

prompt_client_credentials() {
  if [[ -n "${var_client_id:-}" && -n "${var_client_secret:-}" ]]; then
    CLIENT_ID="$var_client_id"
    CLIENT_SECRET="$var_client_secret"
    return 0
  fi

  prompt_endpoint
  read -rp "Machine client ID (from Pangolin dashboard): " CLIENT_ID
  read -rsp "Machine client secret: " CLIENT_SECRET
  echo
  if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" || -z "${PANGOLIN_ENDPOINT}" ]]; then
    msg_error "Pangolin endpoint, client ID, and client secret are required"
    exit 1
  fi
}

select_mode

if [[ -z "${var_target:-}" ]]; then
  while true; do
    read -rp "This will install Pangolin CLI components on the Proxmox host or an existing LXC. Proceed (y/n)? " yn
    case "$yn" in
    [Yy]*) break ;;
    [Nn]*) exit 0 ;;
    *) echo "Please answer yes or no." ;;
    esac
  done
fi

header_info
select_target

# Pre-flight for LXC targets: validate, start, and check the OS before probing it.
if [[ "$TARGET" != "host" ]]; then
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
fi

# Detect an existing standalone Newt install on the target so its credentials
# can be reused and the service swapped to `pangolin up site`.
if [[ "$SITE_ENABLED" == "1" ]]; then
  MIGRATE_FROM_NEWT=""
  LEGACY_NEWT_ID=""
  LEGACY_NEWT_SECRET=""
  LEGACY_ENDPOINT=""

  if [[ "$TARGET" == "host" ]]; then
    if [[ -r /etc/newt/newt.env ]]; then
      set -a
      # shellcheck disable=SC1091
      . /etc/newt/newt.env
      set +a
      LEGACY_NEWT_ID="${NEWT_ID:-}"
      LEGACY_NEWT_SECRET="${NEWT_SECRET:-}"
      LEGACY_ENDPOINT="${PANGOLIN_ENDPOINT:-}"
      unset NEWT_ID NEWT_SECRET PANGOLIN_ENDPOINT
      if [[ -n "$LEGACY_NEWT_ID" && -n "$LEGACY_NEWT_SECRET" && -n "$LEGACY_ENDPOINT" ]]; then
        MIGRATE_FROM_NEWT=1
        msg_warn "Found an existing Newt install on this host — it will be migrated to the Pangolin CLI"
      fi
    fi
  elif [[ -n "${CTID:-}" ]]; then
    # Look for an existing Newt install inside the container and reuse its creds.
    LEGACY_NEWT_ENV="$(pct exec "$CTID" -- sh -c 'if [ -r /etc/newt/newt.env ]; then set -a; . /etc/newt/newt.env; set +a; printf "%s\n%s\n%s\n" "$NEWT_ID" "$NEWT_SECRET" "$PANGOLIN_ENDPOINT"; fi' 2>/dev/null || true)"
    if [[ -n "$LEGACY_NEWT_ENV" ]]; then
      IFS=$'\n' read -r LEGACY_NEWT_ID LEGACY_NEWT_SECRET LEGACY_ENDPOINT <<<"$LEGACY_NEWT_ENV" || true
      if [[ -n "$LEGACY_NEWT_ID" && -n "$LEGACY_NEWT_SECRET" && -n "$LEGACY_ENDPOINT" ]]; then
        MIGRATE_FROM_NEWT=1
        msg_warn "Found an existing Newt install in CT $CTID — it will be migrated to the Pangolin CLI"
      fi
    fi
  fi
fi

[[ "$SITE_ENABLED" == "1" ]] && prompt_site_credentials
[[ "$CLIENT_ENABLED" == "1" ]] && prompt_client_credentials

if [[ "$TARGET" == "host" ]]; then
  msg_warn "Installing on the Proxmox host — the host is directly connected to Pangolin."
  msg_info "Installing Pangolin CLI on the Proxmox host"
  prepare_env
  install_cli_binary
  [[ "$SITE_ENABLED" == "1" ]] && install_site_service "$PANGOLIN_ENDPOINT" "$SITE_ID" "$SITE_SECRET"
  [[ "$CLIENT_ENABLED" == "1" ]] && install_client_service "$PANGOLIN_ENDPOINT" "$CLIENT_ID" "$CLIENT_SECRET"
  msg_ok "Installed Pangolin CLI on the Proxmox host"
  [[ "$SITE_ENABLED" == "1" ]] && msg_info "Site service: systemctl status pangolin-site | Update: update-pangolin-site"
  [[ "$CLIENT_ENABLED" == "1" ]] && msg_info "Client service: systemctl status pangolin-cli | Update: update-pangolin-cli"
  exit 0
fi

# Machine client mode in an LXC needs /dev/net/tun, so configure passthrough
# before installing (returns 1 if the CT config changed and it must be restarted).
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

if [[ "$CLIENT_ENABLED" == "1" ]]; then
  msg_info "Configuring TUN device passthrough for CT $CTID"
  if ensure_lxc_tun "$CTID"; then
    : # conf unchanged
  else
    msg_info "Restarting CT $CTID to apply TUN configuration"
    pct stop "$CTID"
    pct start "$CTID"
    while [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; do
      sleep 2
    done
    msg_ok "Container $CTID is running with TUN"
  fi
fi

tags_add() {
  local current="$1" add="$2"
  if [[ -z "$current" ]]; then
    echo "$add"
  elif [[ "$current" == *"$add"* ]]; then
    echo "$current"
  else
    echo "${current};${add}"
  fi
}

if ! pct exec "$CTID" -- env \
  SITE_ENABLED="$SITE_ENABLED" \
  CLIENT_ENABLED="$CLIENT_ENABLED" \
  PANGOLIN_ENDPOINT="${PANGOLIN_ENDPOINT:-}" \
  SITE_ID="${SITE_ID:-}" \
  SITE_SECRET="${SITE_SECRET:-}" \
  CLIENT_ID="${CLIENT_ID:-}" \
  CLIENT_SECRET="${CLIENT_SECRET:-}" \
  bash -s <<'REMOTE'
set -euo pipefail

msg_info() { echo -e " \e[1;36m➤\e[0m $1"; }
msg_ok() { echo -e " \e[1;32m✔\e[0m $1"; }
msg_error() { echo -e " \e[1;31m✖\e[0m $1"; }
msg_warn() { echo -e " \e[1;33m!\e[0m $1"; }

remove_legacy_newt() {
  if [[ -f /etc/alpine-release ]]; then
    rc-service newt stop 2>/dev/null || true
    rc-update del newt default >/dev/null 2>&1 || true
    rm -f /etc/init.d/newt
  else
    systemctl disable --now newt >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/newt.service
    systemctl daemon-reload
  fi
  rm -f /usr/local/bin/newt /usr/local/bin/newt-start \
    /etc/newt/newt.env /usr/bin/update-newt /root/.newt
  rmdir /etc/newt >/dev/null 2>&1 || true
}

prepare_env() {
  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache curl ca-certificates >/dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl &>/dev/null; then
      apt-get update -qq
      apt-get install -y -qq curl ca-certificates >/dev/null
    fi
  fi
}

cli_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7* | armhf) arch=arm32 ;;
    riscv64) arch=riscv64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
  fi
  case "$arch" in armhf | armel) arch=arm32 ;; esac
  echo "$arch"
}

resolve_cli_version() {
  local version
  version="$(curl -fsSL https://api.github.com/repos/fosrl/cli/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$version" ]] || { echo "Failed to resolve latest Pangolin CLI release" >&2; return 1; }
  echo "$version"
}

install_cli_binary() {
  local arch version current
  arch="$(cli_arch)"
  version="$(resolve_cli_version)"
  current="$(cat /root/.pangolin-cli 2>/dev/null || true)"
  if [[ "${current:-}" == "${version#v}" && -x /usr/local/bin/pangolin ]]; then
    echo "Pangolin CLI ${version} already installed"
    return 0
  fi
  echo "Installing Pangolin CLI ${version}"
  curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
    -o /usr/local/bin/pangolin
  chmod 755 /usr/local/bin/pangolin
  echo "${version#v}" >/root/.pangolin-cli
}

install_site_service() {
  local endpoint="$1"
  local site_id="$2"
  local site_secret="$3"

  install_cli_binary

  install -d -m 0755 /etc/pangolin
  cat >/etc/pangolin/pangolin-site.env <<EOF
SITE_ID=${site_id}
SITE_SECRET=${site_secret}
PANGOLIN_ENDPOINT=${endpoint}
EOF
  chmod 600 /etc/pangolin/pangolin-site.env

  cat >/usr/local/bin/pangolin-site-start <<'START'
#!/bin/sh
set -a
if [ -f /etc/pangolin/pangolin-site.env ]; then
  . /etc/pangolin/pangolin-site.env
fi
export NEWT_ID="${SITE_ID:-${NEWT_ID:-}}"
export NEWT_SECRET="${SITE_SECRET:-${NEWT_SECRET:-}}"
set +a
exec /usr/local/bin/pangolin up site
START
  chmod 700 /usr/local/bin/pangolin-site-start

  remove_legacy_newt

  if [[ -f /etc/alpine-release ]]; then
    cat >/etc/init.d/pangolin-site <<'INIT'
#!/sbin/openrc-run

name="pangolin-site"
description="Pangolin Site connector (CLI)"
command="/usr/local/bin/pangolin-site-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/pangolin-site.log"
error_log="/var/log/pangolin-site.log"

depend() {
    need net
    after firewall
}
INIT
    chmod +x /etc/init.d/pangolin-site
    rc-update add pangolin-site default 2>/dev/null || true
    rc-service pangolin-site restart 2>/dev/null || rc-service pangolin-site start
  else
    cat >/etc/systemd/system/pangolin-site.service <<'UNIT'
[Unit]
Description=Pangolin Site (CLI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/pangolin/pangolin-site.env
ExecStart=/usr/local/bin/pangolin-site-start
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pangolin-site
    systemctl restart pangolin-site
  fi

  cat >/usr/bin/update-pangolin-site <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f /etc/pangolin/pangolin-site.env ]]; then
  echo "No Pangolin Site installation found (/etc/pangolin/pangolin-site.env missing)" >&2
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
  rc-service pangolin-site stop 2>/dev/null || true
else
  systemctl stop pangolin-site 2>/dev/null || true
fi
curl -fsSL "https://github.com/fosrl/cli/releases/download/${version}/pangolin-cli_linux_${arch}" \
  -o /usr/local/bin/pangolin
chmod 755 /usr/local/bin/pangolin
echo "${version#v}" >/root/.pangolin-cli
if [[ -f /etc/alpine-release ]]; then
  rc-service pangolin-site start
else
  systemctl start pangolin-site
fi
echo "Updated Pangolin CLI to ${version}"
UPD
  chmod +x /usr/bin/update-pangolin-site
}

install_client_service() {
  local endpoint="$1"
  local client_id="$2"
  local client_secret="$3"

  install_cli_binary

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

prepare_env
install_cli_binary
if [[ "${SITE_ENABLED}" == "1" ]]; then
  msg_info "Installing Pangolin Site (CLI) in this container"
  install_site_service "${PANGOLIN_ENDPOINT}" "${SITE_ID}" "${SITE_SECRET}"
fi
if [[ "${CLIENT_ENABLED}" == "1" ]]; then
  msg_info "Installing Pangolin CLI machine client in this container"
  install_client_service "${PANGOLIN_ENDPOINT}" "${CLIENT_ID}" "${CLIENT_SECRET}"
fi
REMOTE
then
  msg_error "Installation failed inside CT $CTID"
  exit 1
fi

CTID_CONFIG_PATH="/etc/pve/lxc/${CTID}.conf"
STEP_TAGS="$(awk -F': ' '/^tags:/ {print $2}' "$CTID_CONFIG_PATH" 2>/dev/null || true)"
NEXT_TAGS="$STEP_TAGS"
[[ "$SITE_ENABLED" == "1" ]] && NEXT_TAGS="$(tags_add "$NEXT_TAGS" pangolin-site)"
[[ "$CLIENT_ENABLED" == "1" ]] && NEXT_TAGS="$(tags_add "$NEXT_TAGS" pangolin-cli)"
if [[ -n "$NEXT_TAGS" && "$NEXT_TAGS" != "$STEP_TAGS" ]]; then
  pct set "$CTID" -tags "$NEXT_TAGS"
fi

msg_ok "Installed Pangolin CLI on CT $CTID"
[[ "$SITE_ENABLED" == "1" ]] && msg_info "Site: pct exec $CTID -- update-pangolin-site | systemctl status pangolin-site"
[[ "$CLIENT_ENABLED" == "1" ]] && msg_info "Client: pct exec $CTID -- update-pangolin-cli | systemctl status pangolin-cli"
msg_info "Primary updates: the dashboard keeps the embedded Newt engine updated; the CLI binary is updated with the commands above."