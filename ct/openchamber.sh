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
OPENCHAMBER_USER_UNIT="${OPENCHAMBER_USER_UNIT:-/root/.config/systemd/user/openchamber.service}"
OPENCHAMBER_SYSTEM_UNIT="${OPENCHAMBER_SYSTEM_UNIT:-/etc/systemd/system/openchamber.service}"
OPENCHAMBER_UNIT_NAME="${OPENCHAMBER_UNIT_NAME:-openchamber.service}"
OPENCHAMBER_RUNTIME_DIR="${OPENCHAMBER_RUNTIME_DIR:-/run/user/0}"

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

# OpenChamber's updater only supports a systemd user service: it queues the
# install with `systemd-run --user` and restarts with `systemctl --user`. A
# system unit has no XDG_RUNTIME_DIR or session bus, so its Update button fails
# with "Failed to connect to user scope bus". Run it as root's user service and
# enable lingering so it still starts at boot with no login.
function openchamber_write_user_unit() {
  install -d -m 0755 "$(dirname "$OPENCHAMBER_USER_UNIT")"
  cat >"$OPENCHAMBER_USER_UNIT" <<EOF
[Unit]
Description=OpenChamber web UI (OpenCode)

[Service]
Type=simple
EnvironmentFile=${OPENCHAMBER_ENV_FILE}
Environment=HOME=/root
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/root/.opencode/bin
ExecStart=${OPENCHAMBER_BIN} serve --port ${OPENCHAMBER_PORT} --host 0.0.0.0 --foreground
Restart=always
RestartSec=5
WorkingDirectory=/root
UMask=0022

[Install]
WantedBy=default.target
EOF
}

function openchamber_switch_to_user_service() {
  local had_system_unit=0 healthy=0

  openchamber_write_user_unit

  $STD apt-get install -y dbus-user-session || {
    msg_error "Could not install dbus-user-session (needed for in-app updates)"
    return 1
  }
  loginctl enable-linger root || {
    msg_error "Could not enable lingering for root (the user service would stop at logout)"
    return 1
  }
  export XDG_RUNTIME_DIR="$OPENCHAMBER_RUNTIME_DIR"
  for _ in $(seq 1 30); do
    [[ -S "${XDG_RUNTIME_DIR}/systemd/private" ]] && break
    sleep 1
  done
  if [[ ! -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
    msg_error "Root's systemd user manager did not start (lingering is enabled)"
    return 1
  fi
  systemctl --user daemon-reload
  # dbus-user-session may have been installed after user@0 started, so its
  # socket is not pulled in by the already-active sockets.target.
  systemctl --user start dbus.socket 2>/dev/null || true
  for _ in $(seq 1 15); do
    [[ -S "${XDG_RUNTIME_DIR}/bus" ]] && break
    sleep 1
  done
  if [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    msg_warn "No user D-Bus socket at ${XDG_RUNTIME_DIR}/bus — the in-app Update button will fail"
  fi

  systemctl --user enable "$OPENCHAMBER_UNIT_NAME" || {
    msg_error "Could not enable ${OPENCHAMBER_UNIT_NAME} in root's user manager"
    return 1
  }

  if [[ -f "$OPENCHAMBER_SYSTEM_UNIT" ]]; then
    had_system_unit=1
    msg_info "Moving ${APP} from the system service to root's user service"
    systemctl disable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      systemctl is-active --quiet "$OPENCHAMBER_UNIT_NAME" || break
      sleep 1
    done
  fi

  systemctl --user restart "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 2
  done

  if [[ "$healthy" == "1" ]]; then
    if [[ "$had_system_unit" == "1" ]]; then
      rm -f "$OPENCHAMBER_SYSTEM_UNIT"
      systemctl daemon-reload
    fi
    return 0
  fi

  msg_error "${APP} did not become healthy as a user service"
  msg_error "Check: XDG_RUNTIME_DIR=${OPENCHAMBER_RUNTIME_DIR} journalctl --user -u ${OPENCHAMBER_UNIT_NAME}"
  systemctl --user --no-pager --full status "$OPENCHAMBER_UNIT_NAME" 2>&1 | head -n 20 || true
  if [[ "$had_system_unit" == "1" ]]; then
    msg_warn "Rolling back to the system service"
    systemctl --user disable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    systemctl enable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
  return 1
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x "$OPENCHAMBER_BIN" && ! -f "$OPENCHAMBER_SYSTEM_UNIT" && ! -f "$OPENCHAMBER_USER_UNIT" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating base system"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Base system updated"

  msg_info "Updating OpenCode CLI (v2)"
  $STD bash -c 'curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path'
  if [[ ! -x "$OPENCODE_BIN" ]]; then
    msg_error "OpenCode binary not found at ${OPENCODE_BIN} after update"
    exit 1
  fi
  ln -sf "$OPENCODE_BIN" /usr/local/bin/opencode
  msg_ok "Updated OpenCode CLI"

  msg_info "Updating ${APP}"
  $STD npm install -g @openchamber/web@latest
  # npm's global prefix varies (NodeSource uses /usr); keep the unit's path valid
  if [[ ! -x "$OPENCHAMBER_BIN" ]]; then
    _oc_resolved="$(command -v openchamber 2>/dev/null || true)"
    if [[ -z "$_oc_resolved" ]]; then
      _oc_prefix="$(npm prefix -g 2>/dev/null || true)"
      [[ -n "$_oc_prefix" && -x "${_oc_prefix}/bin/openchamber" ]] && _oc_resolved="${_oc_prefix}/bin/openchamber"
    fi
    [[ -n "$_oc_resolved" && -x "$_oc_resolved" ]] && ln -sf "$_oc_resolved" "$OPENCHAMBER_BIN"
    unset _oc_resolved _oc_prefix
  fi
  if [[ ! -x "$OPENCHAMBER_BIN" ]]; then
    msg_error "${APP} binary not found after npm install (npm prefix: $(npm prefix -g 2>/dev/null || echo unknown))"
    exit 1
  fi
  msg_ok "Updated ${APP}"

  msg_info "Restarting ${APP} as root's systemd user service"
  openchamber_switch_to_user_service || exit 1
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
