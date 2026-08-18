#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://agentgateway.dev/docs/standalone/latest/ | Github: https://github.com/agentgateway/agentgateway

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/agentgateway"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache bash curl ca-certificates openssl jq
  $STD apk add --no-cache newt
else
  $STD apt-get install -y curl ca-certificates openssl jq whiptail
fi
msg_ok "Installed dependencies"

agentgateway_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) return 1 ;;
    esac
  fi
  case "$arch" in
  amd64 | arm64) echo "$arch" ;;
  *) return 1 ;;
  esac
}

ensure_agentgateway_user() {
  if getent passwd agentgateway >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f /etc/alpine-release ]]; then
    adduser -S -D -H -h "${INSTALL_DIR}" -s /sbin/nologin agentgateway
  else
    useradd --system --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin agentgateway
  fi
}

yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

write_agentgateway_config() {
  local targets_csv="$1"
  local mcp_port="$2"
  local admin_addr="$3"
  local api_key="$4"
  local session_key="$5"
  local pair name url count=0
  local tmp_targets

  tmp_targets="$(mktemp)"

  if [[ -n "$targets_csv" ]]; then
    while IFS= read -r pair; do
      pair="${pair#"${pair%%[![:space:]]*}"}"
      pair="${pair%"${pair##*[![:space:]]}"}"
      [[ -z "$pair" ]] && continue
      if [[ "$pair" != *=* ]]; then
        rm -f "$tmp_targets"
        msg_error "Invalid MCP target '${pair}' — use name=http://host:port/path"
        exit 1
      fi
      name="${pair%%=*}"
      url="${pair#*=}"
      name="${name#"${name%%[![:space:]]*}"}"
      name="${name%"${name##*[![:space:]]}"}"
      url="${url#"${url%%[![:space:]]*}"}"
      url="${url%"${url##*[![:space:]]}"}"
      if [[ ! "$name" =~ ^[A-Za-z0-9][-A-Za-z0-9]*$ ]]; then
        rm -f "$tmp_targets"
        msg_error "Invalid target name '${name}' — letters, digits, and hyphens only (no underscores)"
        exit 1
      fi
      if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        rm -f "$tmp_targets"
        msg_error "Invalid target URL for '${name}' — must be http:// or https://"
        exit 1
      fi
      {
        echo "    - name: ${name}"
        echo "      mcp:"
        echo "        host: $(yaml_quote "$url")"
      } >>"$tmp_targets"
      count=$((count + 1))
    done <<<"$(printf '%s\n' "$targets_csv" | tr ',' '\n')"
  fi

  {
    echo "# yaml-language-server: \$schema=https://agentgateway.dev/schema/config"
    echo "config:"
    echo "  adminAddr: ${admin_addr}"
    echo "  statsAddr: 127.0.0.1:15020"
    echo "  readinessAddr: 127.0.0.1:15021"
    echo "  session:"
    echo "    key: $(yaml_quote "$session_key")"
    echo "mcp:"
    echo "  port: ${mcp_port}"
    echo "  prefixMode: always"
    echo "  failureMode: failOpen"
    echo "  policies:"
    echo "    cors:"
    echo "      allowOrigins:"
    echo "        - \"*\""
    echo "      allowHeaders:"
    echo "        - \"*\""
    echo "      exposeHeaders:"
    echo "        - \"Mcp-Session-Id\""
    echo "    apiKey:"
    echo "      mode: strict"
    echo "      keys:"
    echo "        - key: $(yaml_quote "$api_key")"
    echo "          metadata:"
    echo "            user: lan"
    if [[ "$count" -gt 0 ]]; then
      echo "  targets:"
      cat "$tmp_targets"
    fi
  } >"${INSTALL_DIR}/config.yaml"
  rm -f "$tmp_targets"
  chmod 600 "${INSTALL_DIR}/config.yaml"
}

ARCH="$(agentgateway_arch)" || {
  msg_error "Unsupported architecture: $(uname -m) (need amd64 or arm64)"
  exit 1
}

MCP_PORT="${var_mcp_port:-3000}"
ADMIN_PORT="${var_admin_port:-15000}"
ADMIN_BIND="${var_admin_bind:-127.0.0.1}"
if [[ ! "$MCP_PORT" =~ ^[0-9]+$ ]] || [[ ! "$ADMIN_PORT" =~ ^[0-9]+$ ]]; then
  msg_error "var_mcp_port and var_admin_port must be numeric"
  exit 1
fi
ADMIN_ADDR="${ADMIN_BIND}:${ADMIN_PORT}"

stop_spinner
mcp_targets="${var_mcp_targets:-}"
if [[ -z "${mcp_targets}" ]]; then
  silent=0
  [[ "${PHS_SILENT:-0}" == "1" ]] && silent=1
  [[ "${var_unattended:-}" =~ ^(yes|true|1)$ ]] && silent=1
  [[ "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] && silent=1
  [[ ! -t 0 ]] && silent=1
  if [[ "$silent" -eq 0 ]]; then
    mcp_targets="$(prompt_input "${TAB3}MCP backends (name=url, comma-separated, optional):" "" 180)"
  fi
fi

install -d -m 0750 "${INSTALL_DIR}"
ensure_agentgateway_user

msg_info "Installing agentgateway"
fetch_and_deploy_gh_release "agentgateway" "agentgateway/agentgateway" "singlefile" "latest" \
  "/usr/local/bin" "agentgateway-linux-${ARCH}"
msg_ok "Installed agentgateway binary"

API_KEY="$(openssl rand -hex 32)"
SESSION_KEY="$(openssl rand -hex 32)"

cat >"${INSTALL_DIR}/.env" <<EOF
MCP_PORT=${MCP_PORT}
ADMIN_PORT=${ADMIN_PORT}
ADMIN_BIND=${ADMIN_BIND}
AGENTGATEWAY_API_KEY=${API_KEY}
SESSION_KEY=${SESSION_KEY}
HOME=${INSTALL_DIR}
EOF
chmod 600 "${INSTALL_DIR}/.env"

write_agentgateway_config "${mcp_targets}" "${MCP_PORT}" "${ADMIN_ADDR}" "${API_KEY}" "${SESSION_KEY}"

cat >"${INSTALL_DIR}/start.sh" <<EOF
#!/bin/sh
cd ${INSTALL_DIR} || exit 1
export HOME=${INSTALL_DIR}
set -a
# shellcheck disable=SC1091
. ${INSTALL_DIR}/.env
set +a
exec /usr/local/bin/agentgateway -f ${INSTALL_DIR}/config.yaml
EOF
chmod 700 "${INSTALL_DIR}/start.sh"
chown -R agentgateway:agentgateway "${INSTALL_DIR}"

msg_info "Validating config"
if ! /usr/local/bin/agentgateway -f "${INSTALL_DIR}/config.yaml" --validate-only; then
  msg_error "agentgateway config failed validation"
  exit 1
fi
msg_ok "Config valid"

msg_info "Setting up ${APPLICATION:-agentgateway} service"
if [[ -f /etc/alpine-release ]]; then
  touch /var/log/agentgateway.log
  chown agentgateway:agentgateway /var/log/agentgateway.log
  cat >"/etc/init.d/agentgateway" <<EOF
#!/sbin/openrc-run

name="agentgateway"
description="agentgateway MCP federation proxy"
command="${INSTALL_DIR}/start.sh"
command_background=true
command_user=agentgateway
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/agentgateway.log"
error_log="/var/log/agentgateway.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/agentgateway
  $STD rc-update add agentgateway default
  $STD rc-service agentgateway start
else
  cat >"/etc/systemd/system/agentgateway.service" <<EOF
[Unit]
Description=agentgateway MCP federation proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=agentgateway
Group=agentgateway
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/.env
Environment=HOME=${INSTALL_DIR}
ExecStart=/usr/local/bin/agentgateway -f ${INSTALL_DIR}/config.yaml
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $STD systemctl daemon-reload
  $STD systemctl enable --now agentgateway
fi

sleep 3
if [[ -f /etc/alpine-release ]]; then
  if ! rc-service agentgateway status >/dev/null 2>&1; then
    msg_error "agentgateway service failed to start — check /var/log/agentgateway.log"
    exit 1
  fi
else
  if ! systemctl is-active --quiet agentgateway; then
    msg_error "agentgateway service failed to start — check: journalctl -u agentgateway"
    exit 1
  fi
fi
msg_ok "Installed ${APPLICATION:-agentgateway}"

container_ip="${IP:-}"
if [[ -z "$container_ip" || "$container_ip" == "127.0.0.1" || "$container_ip" == "Unknown" ]]; then
  if declare -f get_current_ip >/dev/null 2>&1; then
    container_ip="$(get_current_ip)"
  fi
fi
if [[ -z "$container_ip" || "$container_ip" == "127.0.0.1" || "$container_ip" == "Unknown" ]]; then
  container_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$container_ip" ]] || container_ip="127.0.0.1"

MCP_ENDPOINT="http://${container_ip}:${MCP_PORT}/mcp/http"
if [[ "$ADMIN_BIND" == "127.0.0.1" || "$ADMIN_BIND" == "localhost" ]]; then
  UI_URL="http://127.0.0.1:${ADMIN_PORT}/ui"
else
  UI_URL="http://${container_ip}:${ADMIN_PORT}/ui"
fi
echo "${MCP_ENDPOINT}" >"${INSTALL_DIR}/mcp_endpoint.txt"
echo "${UI_URL}" >"${INSTALL_DIR}/ui_url.txt"
cat >"${INSTALL_DIR}/mcp_client.json" <<EOF
{
  "mcpServers": {
    "agentgateway": {
      "url": "${MCP_ENDPOINT}",
      "headers": {
        "Authorization": "Bearer ${API_KEY}"
      }
    }
  }
}
EOF
chmod 600 "${INSTALL_DIR}/mcp_endpoint.txt" "${INSTALL_DIR}/ui_url.txt" "${INSTALL_DIR}/mcp_client.json"
chown agentgateway:agentgateway "${INSTALL_DIR}/mcp_endpoint.txt" "${INSTALL_DIR}/ui_url.txt" "${INSTALL_DIR}/mcp_client.json" "${INSTALL_DIR}/.env" "${INSTALL_DIR}/config.yaml"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/agentgateway.sh)"
EOF
chmod +x /usr/bin/update

echo -e "${INFO}${YW} MCP endpoint:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${MCP_ENDPOINT}${CL}"
echo -e "${INFO}${YW} Authorization:${CL} Bearer ${API_KEY}"
echo -e "${INFO}${YW} Add to Cursor (~/.cursor/mcp.json):${CL}"
echo -e "${TAB}$(tr -d '\n' <"${INSTALL_DIR}/mcp_client.json")"
echo -e "${INFO}${YW} Admin UI:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${UI_URL}${CL}"
if [[ "$ADMIN_BIND" == "127.0.0.1" || "$ADMIN_BIND" == "localhost" ]]; then
  echo -e "${INFO}${YW} Admin UI is loopback-only. From the Proxmox host: \`ssh -L 15000:127.0.0.1:15000 root@${container_ip}\` then open http://127.0.0.1:15000/ui${CL}"
  echo -e "${INFO}${YW} To bind the UI on the LAN (no auth): reinstall with var_admin_bind=0.0.0.0${CL}"
fi
if [[ -z "${mcp_targets}" ]]; then
  echo -e "${INFO}${YW} No backends yet — add Streamable HTTP servers in the Admin UI (MCP → Servers) or edit /opt/agentgateway/config.yaml.${CL}"
fi

cleanup_lxc
