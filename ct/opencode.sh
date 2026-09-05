#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://opencode.ai/ | Github: https://github.com/anomalyco/opencode

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="OpenCode Server"
NSAPP="opencode"
var_tags="${var_tags:-ai;dev;agent;llm;opencode}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCODE_ENV_FILE="${OPENCODE_ENV_FILE:-/etc/opencode/opencode.env}"

header_info "$APP"
variables
NSAPP="opencode"
var_install="opencode-install"
color
catch_errors

function opencode_primary_ipv4() {
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

function opencode_show_url() {
  local ip
  ip="$(opencode_primary_ipv4)"
  echo -e "${INFO}${YW} Access the OpenCode web UI at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${ip}:${OPENCODE_PORT:-4096}${CL}"
  echo -e "${INFO}${YW} OpenAPI spec:${CL} http://${ip}:${OPENCODE_PORT:-4096}/doc"
}

function opencode_is_installed() {
  [[ -x "$OPENCODE_BIN" ]]
}

function opencode_stop_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service opencode stop || true
  else
    $STD systemctl stop opencode || true
  fi
}

function opencode_start_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service opencode start
  else
    $STD systemctl start opencode
  fi
}

function opencode_restart_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service opencode restart
  else
    $STD systemctl restart opencode
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if ! opencode_is_installed; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "${APP} Update Options" \
    "1" "Update ${APP}" \
    "2" "Remove Unused Packages" \
    "3" "Restart ${APP}")

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
    $STD "$OPENCODE_BIN" upgrade --method curl
    msg_ok "Updated ${APP}"

    msg_info "Restarting ${APP}"
    opencode_restart_service
    msg_ok "Restarted ${APP}"

    msg_ok "Updated successfully!"
    opencode_show_url
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused packages"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk cache clean
    else
      $STD apt autoremove -y
      $STD apt clean
    fi
    msg_ok "Removed unused packages"
    exit
  fi

  if [[ "$UPD" == "3" ]]; then
    msg_info "Restarting ${APP}"
    opencode_restart_service
    msg_ok "Restarted ${APP}"
    opencode_show_url
    exit
  fi
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
echo -e "${INFO}${YW}Web UI username (HTTP Basic):${CL} opencode"
echo -e "${INFO}${YW}Generated password (shown once at install):${CL} stored in ${OPENCODE_ENV_FILE} (mode 0600)"
opencode_show_url