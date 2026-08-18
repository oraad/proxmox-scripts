#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/homeassistant-ai/ha-mcp

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/ha-mcp"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache bash ca-certificates curl openssl tar jq
else
  $STD apt-get install -y curl openssl ca-certificates tar jq
fi

msg_info "Installing uv"
USE_UVX=YES setup_uv || exit 1
export PATH="/usr/local/bin:${PATH}"
UVX_PATH="$(command -v uvx)"
if [[ ! -x "$UVX_PATH" ]]; then
  msg_error "uvx not found after install"
  exit 1
fi
msg_ok "Installed uv (${UVX_PATH})"

stop_spinner
ha_url="${var_ha_url:-}"
ha_token="${var_ha_token:-}"
if [[ -z "$ha_url" || -z "$ha_token" ]]; then
  ha_url="${ha_url:-$(prompt_input "${TAB3}Home Assistant URL [http://homeassistant.local:8123]:" "http://homeassistant.local:8123" 120)}"
  ha_token="${ha_token:-$(prompt_password "${TAB3}Home Assistant long-lived access token:" "" 120)}"
fi
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
$STD "$UVX_PATH" --python 3.14 ha-mcp@latest --version
msg_ok "Cached ha-mcp"

msg_info "Setting up ${APPLICATION:-HA MCP} service"
cat >"${INSTALL_DIR}/start.sh" <<EOF
#!/bin/sh
set -a
. ${INSTALL_DIR}/.env
set +a
exec ${UVX_PATH} --python 3.14 --from ha-mcp@latest ha-mcp-web
EOF
chmod 700 "${INSTALL_DIR}/start.sh"

if [[ -f /etc/alpine-release ]]; then
  cat >"/etc/init.d/ha-mcp" <<EOF
#!/sbin/openrc-run

name="ha-mcp"
description="HA MCP Server"
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
  rc-update add ha-mcp default >/dev/null 2>&1
  $STD rc-service ha-mcp start
else
  cat >"/etc/systemd/system/ha-mcp.service" <<EOF
[Unit]
Description=HA MCP Server (ha-mcp)
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
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now ha-mcp >/dev/null 2>&1
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

msg_ok "Installed ${APPLICATION:-HA MCP}"

container_ip="${IP:-}"
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
fi
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
[[ -n "$container_ip" ]] || container_ip="127.0.0.1"

MCP_ENDPOINT="http://${container_ip}:${MCP_PORT:-8086}${MCP_SECRET_PATH}"
printf '%s\n' "${MCP_ENDPOINT}" >"${INSTALL_DIR}/mcp_endpoint.txt"
jq -n --arg url "$MCP_ENDPOINT" \
  '{mcpServers:{"home-assistant":{url:$url}}}' \
  >"${INSTALL_DIR}/mcp_client.json"
chmod 600 "${INSTALL_DIR}/mcp_endpoint.txt" "${INSTALL_DIR}/mcp_client.json"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/ha-mcp.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc
