#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://inventree.org/ | Github: https://github.com/inventree/InvenTree

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="InvenTree"
NSAPP="inventree"
var_tags="${var_tags:-inventory;management;parts;native}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="inventree"
var_install="inventree-install"
color
catch_errors

function inventree_primary_ipv4() {
  local ip="${LOCAL_IP:-${IP:-}}"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  if declare -f get_current_ip >/dev/null 2>&1; then
    ip="$(get_current_ip)"
    ip="${ip%% *}"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" && "$ip" != "Unknown" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [[ -n "$ip" && "$ip" != "127.0.0.1" ]] || ip="127.0.0.1"
  printf '%s\n' "$ip"
}

function inventree_show_url() {
  local ip
  ip="$(inventree_primary_ipv4)"
  echo -e "${INFO}${YW} Access the InvenTree web UI at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${ip}/${CL}"
  echo -e "${INFO}${YW} API base URL:${CL} http://${ip}/api/"
}

function inventree_is_installed() {
  dpkg-query -W -f='${Status}' inventree 2>/dev/null | grep -q "ok installed"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if ! inventree_is_installed; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "${APP} Update Options" \
    "1" "Update ${APP}" \
    "2" "Remove Unused Packages" \
    "3" "Restart ${APP}")

  if [[ "$UPD" == "1" ]]; then
    msg_info "Updating base system"
    $STD apt update
    $STD apt -y upgrade
    msg_ok "Base system updated"

    msg_info "Updating ${APP}"
    if ! $STD env SETUP_NO_CALLS=true apt-get install --only-upgrade -y inventree; then
      msg_error "${APP} update failed"
      exit 1
    fi
    INVENTREE_VERSION="$(dpkg-query -W -f='${Version}' inventree 2>/dev/null || echo "unknown")"
    echo "${INVENTREE_VERSION}" >/etc/inventree/inventree_version.txt
    msg_ok "Updated ${APP} to ${INVENTREE_VERSION}"

    msg_ok "Updated successfully!"
    inventree_show_url
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused packages"
    $STD apt -y autoremove
    $STD apt clean
    msg_ok "Removed unused packages"
    exit
  fi

  if [[ "$UPD" == "3" ]]; then
    msg_info "Restarting ${APP}"
    $STD inventree restart
    $STD systemctl restart nginx
    msg_ok "Restarted ${APP}"
    inventree_show_url
    exit
  fi
}

function prompt_admin_details() {
  [[ -n "${var_admin_user+x}" ]] && return 0
  is_unattended && return 0

  stop_spinner
  var_admin_user="$(prompt_input "InvenTree admin username:" "admin" 40)"
  var_admin_user="${var_admin_user:-admin}"
  var_admin_email="$(prompt_input "InvenTree admin email:" "admin@inventree.local" 60)"
  var_admin_email="${var_admin_email:-admin@inventree.local}"
  export var_admin_user var_admin_email
}

# Ensure Silent/Verbose/Cancel menu works (start() requires whiptail)
if ! command -v pveversion &>/dev/null && ! command -v whiptail &>/dev/null; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq whiptail >/dev/null 2>&1 || true
fi

start
prompt_admin_details
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Admin credentials (created on first boot):${CL} saved to /etc/inventree/credentials.txt (mode 0600)"
echo -e "${INFO}${YW} Admin username:${CL} ${var_admin_user:-admin}"
inventree_show_url