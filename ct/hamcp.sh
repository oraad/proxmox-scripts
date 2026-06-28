#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/homeassistant-ai/ha-mcp

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="HomeAssistantMCP"
var_tags="${var_tags:-homeassistant;mcp;ai}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-0}"
var_keyctl="${var_keyctl:-0}"
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
color
catch_errors

function hamcp_show_endpoint() {
  local port="8086"
  local path="/mcp"
  if [[ -f /opt/hamcp/.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /opt/hamcp/.env
    set +a
    port="${MCP_PORT:-8086}"
    path="${MCP_SECRET_PATH:-/mcp}"
  fi
  if [[ -f /opt/hamcp/mcp_endpoint.txt ]]; then
    echo -e "${INFO}${YW} Home Assistant MCP endpoint:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}$(cat /opt/hamcp/mcp_endpoint.txt)${CL}"
    return
  fi
  echo -e "${INFO}${YW} Home Assistant MCP endpoint:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${port}${path}/mcp${CL}"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/hamcp/.env ]]; then
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

  UVX_PATH="$(command -v uvx 2>/dev/null || echo /root/.local/bin/uvx)"
  msg_info "Updating ${APP}"
  $STD "$UVX_PATH" --python 3.13 --refresh ha-mcp@latest --version
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service ha-mcp restart
  else
    $STD systemctl restart ha-mcp
  fi
  msg_ok "Updated ${APP}"

  if [[ -f /opt/hamcp/.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /opt/hamcp/.env
    set +a
    echo "http://${IP:-127.0.0.1}:${MCP_PORT:-8086}${MCP_SECRET_PATH:-/mcp}/mcp" >/opt/hamcp/mcp_endpoint.txt
  fi

  msg_ok "Updated successfully!"
  hamcp_show_endpoint
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
hamcp_show_endpoint
