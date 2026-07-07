#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://www.music-assistant.io/ | Github: https://github.com/music-assistant/server

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Music Assistant"
var_tags="${var_tags:-music;media;musicassistant;homeassistant}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
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

  if [[ ! -f /opt/musicassistant/compose.yaml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "Music Assistant Update Options" \
    "1" "Update Music Assistant" \
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
    cd /opt/musicassistant
    $STD docker compose pull
    $STD docker compose up -d
    docker inspect ghcr.io/music-assistant/server:latest --format='{{index .RepoDigests 0}}' 2>/dev/null \
      | awk -F@ '{print $2}' > /opt/musicassistant/musicassistant_version.txt || true
    msg_ok "Updated ${APP}"

    msg_ok "Updated successfully!"
    echo -e "${INFO}${YW} Access Music Assistant at:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8095${CL}"
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused images"
    $STD docker image prune -af
    msg_ok "Removed unused images"
    exit
  fi
}

function prompt_music_library_host() {
  [[ -n "${var_media_path+x}" ]] && return 0
  is_unattended && return 0

  stop_spinner
  var_media_path="$(prompt_input "${TAB3}Mount a host music library into the container at /media? (host path or leave empty):" "" 60)"
  if [[ -n "${var_media_path}" && ! -d "${var_media_path}" ]]; then
    msg_warn "Host path not found: ${var_media_path} — skipping media mount"
    var_media_path=""
  fi
  export var_media_path
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
prompt_music_library_host
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access Music Assistant at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8095${CL}"
