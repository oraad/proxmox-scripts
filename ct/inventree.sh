#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://inventree.org/ | Github: https://github.com/inventree/InvenTree

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="InvenTree"
NSAPP="inventree"
var_tags="${var_tags:-inventory;management;parts;docker}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

INVENTREE_DIR="${INVENTREE_DIR:-/opt/inventree}"

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

function inventree_wait_docker_health() {
  local name="$1" max="${2:-120}" i status
  for ((i = 0; i < max; i++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

function inventree_record_version() {
  local img image
  img="$(docker inspect inventree-server --format='{{.Config.Image}}' 2>/dev/null || true)"
  image=""
  [[ -n "$img" ]] && image="$(docker image inspect "$img" --format='{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')"
  echo "${image:-latest}" >"${INVENTREE_DIR}/inventree_version.txt"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/inventree/docker-compose.yml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "${APP} Update Options" \
    "1" "Update ${APP}" \
    "2" "Remove Unused Images" \
    "3" "Restart ${APP} Stack")

  if [[ "$UPD" == "1" ]]; then
    msg_info "Updating base system"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk -U upgrade
    else
      $STD apt update
      $STD apt -y upgrade
    fi
    msg_ok "Base system updated"

    msg_info "Stopping ${APP} stack"
    cd /opt/inventree
    $STD docker compose down
    msg_ok "Stopped ${APP} stack"

    msg_info "Updating ${APP} images"
    $STD docker compose pull
    msg_ok "Updated ${APP} images"

    msg_info "Starting database before migrations"
    $STD docker compose up -d inventree-db inventree-cache
    if ! inventree_wait_docker_health inventree-db 180; then
      msg_error "InvenTree database did not become healthy"
      exit 1
    fi
    msg_ok "Database ready"

    msg_info "Running database migrations (invoke update)"
    if $STD docker compose run --rm -T inventree-server invoke update; then
      msg_ok "Migrations complete"
    else
      msg_error "Database migration failed"
      exit 1
    fi

    msg_info "Starting ${APP} stack"
    $STD docker compose up -d
    msg_ok "Started ${APP} stack"

    msg_info "Confirming container health"
    if ! inventree_wait_docker_health inventree-proxy 240; then
      msg_warn "The web server did not report healthy within 8 minutes — check: docker compose logs"
    fi

    inventree_record_version
    msg_ok "Updated ${APP} successfully!"
    inventree_show_url
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused images"
    $STD docker image prune -af
    msg_ok "Removed unused images"
    exit
  fi

  if [[ "$UPD" == "3" ]]; then
    msg_info "Restarting ${APP} stack"
    cd /opt/inventree
    $STD docker compose restart
    msg_ok "Restarted ${APP} stack"
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
  if [[ -f /etc/alpine-release ]]; then
    apk add --no-cache newt >/dev/null 2>&1 || true
  else
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq whiptail >/dev/null 2>&1 || true
  fi
fi

start
prompt_admin_details
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Admin credentials (created on first boot):${CL} saved to ${INVENTREE_DIR}/credentials.txt (mode 0600)"
echo -e "${INFO}${YW} Admin username:${CL} ${var_admin_user:-admin}"
inventree_show_url