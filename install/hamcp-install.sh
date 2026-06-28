#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/homeassistant-ai/ha-mcp

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/hamcp"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -f /etc/alpine-release ]]; then
  $STD apk add curl openssl
else
  $STD apt-get install -y curl openssl
fi

msg_info "Installing uv"
$STD sh -c "$(curl -fsSL https://astral.sh/uv/install.sh)"
export PATH="/root/.local/bin:${PATH}"
UVX_PATH="$(command -v uvx)"
if [[ ! -x "$UVX_PATH" ]]; then
  msg_error "uvx not found after install"
  exit 1
fi
msg_ok "Installed uv (${UVX_PATH})"

msg_info "Configuring Home Assistant connection"
read -r -p "${TAB3}Home Assistant URL [http://homeassistant.local:8123]: " ha_url
ha_url="${ha_url:-http://homeassistant.local:8123}"
read -r -s -p "${TAB3}Home Assistant long-lived access token: " ha_token
echo
if [[ -z "${ha_token}" ]]; then
  msg_error "HOMEASSISTANT_TOKEN is required"
  exit 1
fi

MCP_SECRET_PATH="/mcp-$(openssl rand -hex 16)"
mkdir -p "${INSTALL_DIR}"
chmod 700 "${INSTALL_DIR}"

msg_info "Checking Home Assistant connectivity"
if ! curl -sf -H "Authorization: Bearer ${ha_token}" "${ha_url%/}/api/" >/dev/null; then
  msg_error "Cannot reach Home Assistant at ${ha_url} — check URL, token, and network"
  exit 1
fi
msg_ok "Home Assistant API reachable"

cat >"${INSTALL_DIR}/.env" <<EOF
HOMEASSISTANT_URL=${ha_url}
HOMEASSISTANT_TOKEN=${ha_token}
MCP_HOST=0.0.0.0
MCP_PORT=8086
MCP_SECRET_PATH=${MCP_SECRET_PATH}
EOF
chmod 600 "${INSTALL_DIR}/.env"

msg_info "Pre-caching ha-mcp"
$STD "$UVX_PATH" --python 3.13 ha-mcp@latest --version
msg_ok "Cached ha-mcp"

msg_info "Setting up ${APPLICATION:-Home Assistant MCP} service"
cat >"${INSTALL_DIR}/start.sh" <<EOF
#!/bin/sh
set -a
. ${INSTALL_DIR}/.env
set +a
exec ${UVX_PATH} --python 3.13 ha-mcp-web
EOF
chmod 700 "${INSTALL_DIR}/start.sh"

if [[ -f /etc/alpine-release ]]; then
  cat >"/etc/init.d/ha-mcp" <<EOF
#!/sbin/openrc-run

name="ha-mcp"
description="Home Assistant MCP Server"
command="${INSTALL_DIR}/start.sh"
command_background=true
command_user=root
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/ha-mcp.log"
error_log="/var/log/ha-mcp.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/ha-mcp
  $STD rc-update add ha-mcp default
  $STD rc-service ha-mcp start
else
  cat >"/etc/systemd/system/ha-mcp.service" <<EOF
[Unit]
Description=Home Assistant MCP Server (ha-mcp)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  $STD systemctl daemon-reload
  $STD systemctl enable --now ha-mcp
fi

sleep 2
if [[ -f /etc/alpine-release ]]; then
  if ! rc-service ha-mcp status >/dev/null 2>&1; then
    msg_error "ha-mcp service failed to start — check /var/log/ha-mcp.log"
    exit 1
  fi
else
  if ! systemctl is-active --quiet ha-mcp; then
    msg_error "ha-mcp service failed to start — check: journalctl -u ha-mcp"
    exit 1
  fi
fi

MCP_ENDPOINT="http://${IP:-127.0.0.1}:8086${MCP_SECRET_PATH}/mcp"
echo "${MCP_ENDPOINT}" >"${INSTALL_DIR}/mcp_endpoint.txt"
chmod 600 "${INSTALL_DIR}/mcp_endpoint.txt"
msg_ok "Installed ${APPLICATION:-Home Assistant MCP}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/hamcp.sh)"
EOF
chmod +x /usr/bin/update

echo -e "${INFO}${YW} Home Assistant MCP endpoint:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${MCP_ENDPOINT}${CL}"
echo -e "${INFO}${YW} Add to Cursor (~/.cursor/mcp.json):${CL}"
echo -e "${TAB}{ \"mcpServers\": { \"home-assistant\": { \"url\": \"${MCP_ENDPOINT}\" } } }"

cleanup_lxc
