#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/oraad/solar-ai-optimizer

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Solar AI Optimizer"
NSAPP="solar-ai-optimizer"
var_tags="${var_tags:-homeassistant;solar;docker}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_os="${var_os:-debian}"
if [[ "$var_os" == "alpine" ]]; then
  var_disk="${var_disk:-4}"
  var_version="${var_version:-3.24}"
else
  var_disk="${var_disk:-8}"
  var_version="${var_version:-13}"
fi
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"
var_keyctl="${var_keyctl:-1}"
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="solar-ai-optimizer"
var_install="solar-ai-optimizer-install"
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # shellcheck disable=SC1090
  source <(curl -fsSL "${REPO_RAW}/misc/solar-common.sh")

  if ! solar_is_installed; then
    if solar_recover_missing_container; then
      msg_info "Waiting for health check"
      if solar_wait_healthy 127.0.0.1 "$SOLAR_PORT" "$SOLAR_HEALTH_PATH" 120; then
        msg_ok "Service is healthy"
      else
        msg_warn "Health check timed out — check: docker logs ${SOLAR_CONTAINER}"
      fi
      solar_show_admin_credentials
      msg_ok "Recovered successfully!"
      exit
    fi
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if ! command -v whiptail &>/dev/null; then
    if [[ -f /etc/alpine-release ]]; then
      apk add --no-cache newt >/dev/null 2>&1 || true
    else
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq whiptail >/dev/null 2>&1 || true
    fi
  fi

  UPD=$(msg_menu "Solar AI Optimizer Update Options" \
    "1" "Update Solar AI Optimizer" \
    "2" "Remove Unused Images")

  if [[ "$UPD" == "1" ]]; then
    solar_write_update_command

    msg_info "Updating base system"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk -U upgrade
    else
      $STD apt update
      $STD apt -y upgrade
    fi
    msg_ok "Base system updated"

    local previous current env_patched=0 previous_image_id=""
    previous="$(solar_installed_ref)"

    msg_info "Ensuring auth configuration"
    solar_ensure_env_auth
    env_patched="${SOLAR_ENV_PATCHED:-0}"

    if docker inspect "$SOLAR_CONTAINER" >/dev/null 2>&1; then
      previous_image_id="$(docker inspect -f '{{.Image}}' "$SOLAR_CONTAINER" 2>/dev/null || echo "")"
    fi

    msg_info "Pulling latest image"
    $STD docker pull "$(solar_image_ref)"
    msg_ok "Pulled $(solar_image_ref)"

    current="$(solar_current_image_ref)"
    if [[ -n "$previous" && "$previous" == "$current" && "$env_patched" != "1" ]]; then
      msg_ok "No update required. ${APP} is already running the latest image."
      echo -e "${INFO}${YW} Access the dashboard at:${CL}"
      echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${SOLAR_PORT:-8000}${CL}"
      exit
    fi

    if [[ -n "$previous" && "$previous" == "$current" ]]; then
      msg_ok "${APP} is already running the latest image."
    fi

    msg_info "Recreating container (data volume preserved)"
    $STD solar_recreate_container
    solar_save_version
    msg_ok "Container recreated"

    msg_info "Waiting for health check"
    if solar_wait_healthy 127.0.0.1 "$SOLAR_PORT" "$SOLAR_HEALTH_PATH" 120; then
      msg_ok "Service is healthy"
    else
      msg_warn "Health check timed out — check: docker logs ${SOLAR_CONTAINER}"
    fi

    msg_info "Cleaning up old images"
    solar_cleanup_old_images "$previous_image_id"
    msg_ok "Old images cleaned up"

    solar_show_admin_credentials

    msg_ok "Updated successfully!"
    echo -e "${INFO}${YW} Access the dashboard at:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${SOLAR_PORT:-8000}${CL}"
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused images"
    $STD docker image prune -af
    msg_ok "Removed unused images"
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
echo -e "${INFO}${YW} Access the dashboard at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${SOLAR_PORT:-8000}${CL}"
echo -e "${INFO}${YW} Starts in SHADOW MODE — configure Home Assistant in Settings before going live.${CL}"

_SOLAR_CREDS_FILE="/opt/solar-ai-optimizer/.install-admin-credentials"
if pct exec "$CTID" test -f "$_SOLAR_CREDS_FILE" 2>/dev/null; then
  _solar_admin_user="$(pct exec "$CTID" sed -n '1p' "$_SOLAR_CREDS_FILE" 2>/dev/null | tr -d '\r')"
  _solar_admin_pass="$(pct exec "$CTID" sed -n '2p' "$_SOLAR_CREDS_FILE" 2>/dev/null | tr -d '\r')"
  pct exec "$CTID" rm -f "$_SOLAR_CREDS_FILE" 2>/dev/null || true
  if [[ -n "$_solar_admin_user" && -n "$_solar_admin_pass" ]]; then
    echo -e "${INFO}${YW} Local admin login (save these — not shown again):${CL}"
    echo -e "${INFO}${YW} Username:${CL} ${_solar_admin_user}"
    echo -e "${INFO}${YW} Password:${CL} ${_solar_admin_pass}"
  fi
fi
