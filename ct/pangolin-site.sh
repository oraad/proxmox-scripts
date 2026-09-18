#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/cli | https://github.com/fosrl/newt

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Pangolin Site"
NSAPP="pangolin-site"
var_tags="${var_tags:-network;pangolin}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-2}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_tun="${var_tun:-yes}"
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="pangolin-site"
var_install="pangolin-site-install"
color
catch_errors

function pangolin_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7* | armhf) arch=arm32 ;;
    riscv64) arch=riscv64 ;;
    *) return 1 ;;
    esac
  fi
  case "$arch" in
  armhf | armel) arch=arm32 ;;
  esac
  echo "$arch"
}

function pangolin_site_stop_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service pangolin-site stop || true
  else
    $STD systemctl stop pangolin-site || true
  fi
}

function pangolin_site_start_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service pangolin-site start
  else
    $STD systemctl start pangolin-site
  fi
}

# In-place migration from the standalone Newt binary to the Pangolin CLI site
# mode. Reuses the same site ID/secret/endpoint; no new credentials are needed.
function migrate_legacy_newt() {
  local arch="$1"
  local old_id old_secret old_endpoint

  set -a
  # shellcheck disable=SC1091
  source /etc/newt/newt.env
  set +a
  old_id="${NEWT_ID:-}"
  old_secret="${NEWT_SECRET:-}"
  old_endpoint="${PANGOLIN_ENDPOINT:-}"

  if [[ -z "$old_id" || -z "$old_secret" || -z "$old_endpoint" ]]; then
    msg_error "Could not read credentials from /etc/newt/newt.env"
    exit 1
  fi

  msg_info "Installing Pangolin CLI (site mode)"
  fetch_and_deploy_gh_release "pangolin-cli" "fosrl/cli" "singlefile" "latest" \
    "/usr/local/bin" "pangolin-cli_linux_${arch}"
  msg_ok "Installed Pangolin CLI binary"

  install -d -m 0755 /etc/pangolin
  cat >/etc/pangolin/pangolin-site.env <<EOF
SITE_ID=${old_id}
SITE_SECRET=${old_secret}
PANGOLIN_ENDPOINT=${old_endpoint}
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

  if [[ -f /etc/alpine-release ]]; then
    rc-service newt stop 2>/dev/null || true
    rc-update del newt default >/dev/null 2>&1 || true
    rm -f /etc/init.d/newt

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
    systemctl disable --now newt >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/newt.service

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

  rm -f /usr/local/bin/newt /usr/local/bin/newt-start \
    /etc/newt/newt.env /usr/bin/update-newt /root/.newt
  rmdir /etc/newt >/dev/null 2>&1 || true
}

function ensure_update_script() {
  # Point the container's update command at this script so the legacy
  # ct/newt.sh URL can eventually be removed. The running file is truncated
  # first so a shell executing a stale /usr/bin/update hits EOF instead of
  # re-reading garbage from the file being replaced underneath it.
  cat >/usr/bin/update.new <<EOF
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/pangolin-site.sh)"
EOF
  : >/usr/bin/update
  chmod +x /usr/bin/update.new
  mv -f /usr/bin/update.new /usr/bin/update
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  ensure_update_script

  local has_legacy_newt=0
  if [[ -f /etc/newt/newt.env && ! -f /etc/pangolin/pangolin-site.env ]]; then
    has_legacy_newt=1
  fi

  if [[ "$has_legacy_newt" == "0" && ! -f /etc/pangolin/pangolin-site.env ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating base system"
  if [[ -f /etc/alpine-release ]]; then
    $STD apk -U upgrade
  else
    $STD apt update
    $STD apt -y upgrade
  fi
  msg_ok "Base system updated"

  local arch
  if ! arch="$(pangolin_arch)"; then
    msg_error "Unsupported architecture: $(uname -m)"
    exit
  fi

  if [[ "$has_legacy_newt" == "1" ]]; then
    msg_warn "Legacy Newt install detected — migrating to the Pangolin CLI (site mode)"
    migrate_legacy_newt "$arch"
    msg_ok "Migrated legacy Newt to the Pangolin CLI"
  fi

  if check_for_gh_release "pangolin-cli" "fosrl/cli"; then
    msg_info "Stopping ${APP}"
    pangolin_site_stop_service
    msg_ok "Stopped ${APP}"

    fetch_and_deploy_gh_release "pangolin-cli" "fosrl/cli" "singlefile" "latest" \
      "/usr/local/bin" "pangolin-cli_linux_${arch}"

    msg_info "Starting ${APP}"
    pangolin_site_start_service
    msg_ok "Started ${APP}"
    msg_ok "Updated successfully!"
  fi

  if [[ -f /etc/pangolin/pangolin-site.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/pangolin/pangolin-site.env
    set +a
    echo -e "${INFO}${YW} Pangolin endpoint:${CL} ${PANGOLIN_ENDPOINT:-unknown}"
    echo -e "${INFO}${YW} Site ID:${CL} ${SITE_ID:-unknown}"
  fi
  echo -e "${INFO}${YW} Update the CLI binary with /usr/bin/update, or enable Automatic Site Updates in the Pangolin dashboard for the embedded Newt engine.${CL}"
  exit
}

# Ensure Silent/Verbose/Cancel menu works (start() requires whiptail)
if ! command -v pveversion &>/dev/null && ! command -v whiptail &>/dev/null; then
  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache newt >/dev/null 2>&1 || true
  else
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq whiptail >/dev/null 2>&1 || true
  fi
fi

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Pangolin Site (CLI) connects outbound to your Pangolin control plane (no local web UI).${CL}"
echo -e "${INFO}${YW} The site tunnel runs as 'pangolin up site' — Newt, embedded in the official Pangolin CLI.${CL}"
echo -e "${INFO}${YW} Update the CLI binary in-container with \`update\` or \`pct exec <CTID> -- update\`.${CL}"
