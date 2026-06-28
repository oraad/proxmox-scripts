#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://www.music-assistant.io/ | Github: https://github.com/music-assistant/server

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="MusicAssistant"
var_tags="${var_tags:-music;media;homeassistant}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-1}"
var_keyctl="${var_keyctl:-1}"
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
    | awk -F@ '{print $2}' > /opt/musicassistant_version.txt || true
  msg_ok "Updated ${APP}"

  msg_ok "Updated successfully!"
  echo -e "${INFO}${YW} Access Music Assistant at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8095${CL}"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access Music Assistant at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8095${CL}"
