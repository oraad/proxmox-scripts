#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://netalertx.com/ | Github: https://github.com/netalertx/NetAlertX

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="NetAlertX"
var_tags="${var_tags:-network;monitoring;netalertx}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-0}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/netalertx/compose.yaml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "NetAlertX Update Options" \
    "1" "Update NetAlertX" \
    "2" "Remove Unused Images")

  if [[ "$UPD" == "1" ]]; then
    msg_info "Updating base system"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk -U upgrade
    else
      $STD apt update
      $STD apt -y upgrade
    fi
    msg_ok "Base system updated"

    msg_info "Updating ${APP}"
    cd /opt/netalertx
    $STD docker compose pull
    $STD docker compose up -d
    docker inspect ghcr.io/netalertx/netalertx:latest --format='{{index .RepoDigests 0}}' 2>/dev/null \
      | awk -F@ '{print $2}' > /opt/netalertx/netalertx_version.txt || true
    msg_ok "Updated ${APP}"

    msg_ok "Updated successfully!"
    echo -e "${INFO}${YW} Access NetAlertX at:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:20211${CL}"
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused images"
    $STD docker image prune -af
    msg_ok "Removed unused images"
    exit
  fi
}

function prompt_scan_subnets() {
  [[ -n "${var_scan_subnets+x}" ]] && return 0
  is_unattended && return 0

  stop_spinner
  local subnet iface
  subnet="$(prompt_input "${TAB3}SCAN_SUBNETS CIDR (e.g. 192.168.1.0/24, leave empty to configure in UI):" "" 60)"
  if [[ -z "${subnet}" ]]; then
    var_scan_subnets=""
    export var_scan_subnets
    return 0
  fi
  iface="$(prompt_input "${TAB3}Network interface for scanning (e.g. eth0):" "eth0" 60)"
  iface="${iface:-eth0}"
  var_scan_subnets="['${subnet} --interface=${iface}']"
  export var_scan_subnets
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
prompt_scan_subnets
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access NetAlertX at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:20211${CL}"
