#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/homeassistant-ai/ha-mcp

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="HA MCP"
NSAPP="ha-mcp"
var_tags="${var_tags:-homeassistant;mcp;ai}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="ha-mcp"
var_install="ha-mcp-install"
color
catch_errors

function ha_mcp_show_endpoint() {
  local port="8086"
  local path="/mcp"
  if [[ -f /opt/ha-mcp/.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /opt/ha-mcp/.env
    set +a
    port="${MCP_PORT:-8086}"
    path="${MCP_SECRET_PATH:-/mcp}"
  fi
  if [[ -f /opt/ha-mcp/mcp_endpoint.txt ]]; then
    echo -e "${INFO}${YW} HA MCP endpoint:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}$(cat /opt/ha-mcp/mcp_endpoint.txt)${CL}"
    return
  fi
  echo -e "${INFO}${YW} HA MCP endpoint:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:${port}${path}/mcp${CL}"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/ha-mcp/.env ]]; then
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

  UVX_PATH="$(command -v uvx 2>/dev/null || echo /usr/local/bin/uvx)"
  msg_info "Updating ${APP}"
  $STD "$UVX_PATH" --python 3.13 --refresh ha-mcp@latest --version
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service ha-mcp restart
  else
    $STD systemctl restart ha-mcp
  fi
  msg_ok "Updated ${APP}"

  if [[ -f /opt/ha-mcp/.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source /opt/ha-mcp/.env
    set +a
    echo "http://${IP:-127.0.0.1}:${MCP_PORT:-8086}${MCP_SECRET_PATH:-/mcp}/mcp" >/opt/ha-mcp/mcp_endpoint.txt
  fi

  msg_ok "Updated successfully!"
  ha_mcp_show_endpoint
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
ha_mcp_show_endpoint
