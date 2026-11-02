#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://openchamber.dev/ | Github: https://github.com/openchamber/openchamber

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="OpenChamber"
NSAPP="openchamber"
var_tags="${var_tags:-opencode;ai;code;web;openchamber}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
var_arm64="${var_arm64:-yes}"

OPENCHAMBER_BIN="${OPENCHAMBER_BIN:-/usr/local/bin/openchamber}"
OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
OPENCHAMBER_ENV_FILE="${OPENCHAMBER_ENV_FILE:-/etc/openchamber/openchamber.env}"
OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"

header_info "$APP"
variables
NSAPP="openchamber"
var_install="openchamber-install"
color
catch_errors

function openchamber_primary_ipv4() {
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

function openchamber_show_url() {
  local ip
  ip="$(openchamber_primary_ipv4)"
  echo -e "${INFO}${YW} Access the OpenChamber web UI at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${ip}:${OPENCHAMBER_PORT:-3000}${CL}"
  echo -e "${INFO}${YW} UI password stored in:${CL} ${OPENCHAMBER_ENV_FILE} (mode 0600)"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x "$OPENCHAMBER_BIN" && ! -f /etc/systemd/system/openchamber.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating base system"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Base system updated"

  msg_info "Updating OpenCode CLI"
  $STD bash -c 'curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path'
  if [[ ! -x "$OPENCODE_BIN" ]]; then
    msg_error "OpenCode binary not found at ${OPENCODE_BIN} after update"
    exit 1
  fi
  ln -sf "$OPENCODE_BIN" /usr/local/bin/opencode
  msg_ok "Updated OpenCode CLI"

  msg_info "Updating ${APP}"
  $STD npm install -g @openchamber/web@latest
  if [[ ! -x "$OPENCHAMBER_BIN" ]]; then
    msg_error "${APP} binary not found at ${OPENCHAMBER_BIN} after update"
    exit 1
  fi
  msg_ok "Updated ${APP}"

  msg_info "Restarting ${APP}"
  $STD systemctl restart openchamber
  msg_ok "Restarted ${APP}"

  msg_info "Waiting for ${APP} to become healthy"
  local retries=0
  until curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [[ "$retries" -ge 30 ]]; then
      msg_error "${APP} did not become healthy — check: journalctl -u openchamber"
      exit 1
    fi
    sleep 2
  done
  msg_ok "${APP} is healthy"

  msg_ok "Updated successfully!"
  openchamber_show_url
  exit
}

function prompt_ui_password() {
  if [[ -n "${var_ui_password:-}" ]]; then
    export var_ui_password
    return 0
  fi

  if declare -f is_unattended >/dev/null 2>&1 && is_unattended; then
    return 0
  fi
  [[ "${PHS_SILENT:-0}" == "1" ]] && return 0
  [[ "${var_unattended:-}" =~ ^(yes|true|1)$ ]] && return 0
  [[ "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] && return 0
  [[ ! -t 0 ]] && return 0

  command -v stop_spinner >/dev/null 2>&1 && stop_spinner

  local generated
  generated="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  var_ui_password="$(prompt_password "${TAB3}OpenChamber UI password:" "$generated" 120)"
  export var_ui_password
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
prompt_ui_password
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Generated UI password (shown once at install):${CL} stored in ${OPENCHAMBER_ENV_FILE} (mode 0600)"
openchamber_show_url
