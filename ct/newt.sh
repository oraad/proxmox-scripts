#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/newt

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Pangolin Newt"
NSAPP="newt"
var_tags="${var_tags:-network;pangolin;newt}"
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
NSAPP="newt"
var_install="newt-install"
color
catch_errors

function newt_arch() {
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

function newt_stop_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service newt stop || true
  else
    $STD systemctl stop newt || true
  fi
}

function newt_start_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service newt start
  else
    $STD systemctl start newt
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /etc/newt/newt.env ]]; then
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
  if ! arch="$(newt_arch)"; then
    msg_error "Unsupported architecture: $(uname -m)"
    exit
  fi

  if check_for_gh_release "newt" "fosrl/newt"; then
    msg_info "Stopping ${APP}"
    newt_stop_service
    msg_ok "Stopped ${APP}"

    fetch_and_deploy_gh_release "newt" "fosrl/newt" "singlefile" "latest" \
      "/usr/local/bin" "newt_linux_${arch}"

    msg_info "Starting ${APP}"
    newt_start_service
    msg_ok "Started ${APP}"
    msg_ok "Updated successfully!"
  fi

  if [[ -f /etc/newt/newt.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/newt/newt.env
    set +a
    echo -e "${INFO}${YW} Pangolin endpoint:${CL} ${PANGOLIN_ENDPOINT:-unknown}"
    echo -e "${INFO}${YW} Newt ID:${CL} ${NEWT_ID:-unknown}"
  fi
  echo -e "${INFO}${YW} Primary updates: enable Automatic Site Updates in the Pangolin dashboard (Newt ≥ 1.13.0).${CL}"
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
echo -e "${INFO}${YW} Newt connects outbound to your Pangolin control plane (no local web UI).${CL}"
echo -e "${INFO}${YW} Enable Automatic Site Updates in Pangolin for hands-off binary updates.${CL}"
echo -e "${INFO}${YW} Manual fallback: run \`update\` inside the LXC or \`pct exec <CTID> -- update\`.${CL}"
