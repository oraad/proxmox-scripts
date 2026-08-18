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
  $STD apk add --no-cache bash curl ca-certificates openssl jq apache2-utils
  $STD apk add --no-cache newt
else
  $STD apt-get install -y curl ca-certificates openssl jq whiptail apache2-utils
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

write_htpasswd() {
  local user="$1"
  local password="$2"
  local dest="$3"
  local line
  if command -v htpasswd >/dev/null 2>&1; then
    line="$(htpasswd -nbB "$user" "$password")"
  else
    line="${user}:$(openssl passwd -apr1 "$password")"
  fi
  printf '%s\n' "$line" >"$dest"
  chmod 600 "$dest"
}

write_agentgateway_config() {
  local targets_csv="$1"
  local public_port="$2"
  local admin_addr="$3"
  local api_key="$4"
  local session_key="$5"
  local htpasswd_file="$6"
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
    echo "gateways:"
    echo "  default:"
    echo "    port: ${public_port}"
    echo "ui:"
    echo "  gateways:"
    echo "    - default"
    echo "  policies:"
    echo "    basicAuth:"
    echo "      mode: strict"
    echo "      realm: Agent Gateway"
    echo "      htpasswd:"
    echo "        file: $(yaml_quote "$htpasswd_file")"
    echo "mcp:"
    echo "  gateways:"
    echo "    - default"
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
    echo "      mode: optional"
    echo "      keys:"
    echo "        - key: $(yaml_quote "$api_key")"
    echo "          metadata:"
    echo "            user: lan"
    echo "    basicAuth:"
    echo "      mode: optional"
    echo "      realm: Agent Gateway"
    echo "      htpasswd:"
    echo "        file: $(yaml_quote "$htpasswd_file")"
    echo "    authorization:"
    echo "      rules:"
    echo "        - allow: 'request.method == \"OPTIONS\"'"
    echo "        - allow: 'has(apiKey.key) || has(basicAuth.username)'"
    if [[ "$count" -gt 0 ]]; then
      echo "  targets:"
      cat "$tmp_targets"
    else
      echo "  targets: []"
    fi
  } >"${INSTALL_DIR}/config.yaml"
  rm -f "$tmp_targets"
  chmod 600 "${INSTALL_DIR}/config.yaml"
}

ARCH="$(agentgateway_arch)" || {
  msg_error "Unsupported architecture: $(uname -m) (need amd64 or arm64)"
  exit 1
}

PUBLIC_PORT="${var_public_port:-${var_mcp_port:-8080}}"
ADMIN_PORT="${var_admin_port:-15000}"
ADMIN_BIND="${var_admin_bind:-127.0.0.1}"
UI_USER="${var_ui_user:-admin}"
HTPASSWD_FILE="${INSTALL_DIR}/htpasswd"
if [[ ! "$PUBLIC_PORT" =~ ^[0-9]+$ ]] || [[ ! "$ADMIN_PORT" =~ ^[0-9]+$ ]]; then
  msg_error "var_public_port (or var_mcp_port) and var_admin_port must be numeric"
  exit 1
fi
if [[ ! "$UI_USER" =~ ^[A-Za-z0-9][-A-Za-z0-9._]*$ ]]; then
  msg_error "var_ui_user must be letters, digits, dots, underscores, or hyphens"
  exit 1
fi
ADMIN_ADDR="${ADMIN_BIND}:${ADMIN_PORT}"

install -d -m 0750 "${INSTALL_DIR}"
ensure_agentgateway_user

msg_info "Installing agentgateway"
fetch_and_deploy_gh_release "agentgateway" "agentgateway/agentgateway" "singlefile" "latest" \
  "/usr/local/bin" "agentgateway-linux-${ARCH}"
msg_ok "Installed agentgateway binary"

if [[ -n "${var_api_key:-}" ]]; then
  API_KEY="${var_api_key}"
else
  API_KEY="$(openssl rand -hex 32)"
fi
if [[ -z "$API_KEY" ]]; then
  msg_error "API key must not be empty (set var_api_key or allow it to be generated)"
  exit 1
fi
if [[ -n "${var_ui_password:-}" ]]; then
  UI_PASSWORD="${var_ui_password}"
else
  UI_PASSWORD="$(openssl rand -hex 16)"
fi
if [[ -z "$UI_PASSWORD" ]]; then
  msg_error "UI password must not be empty (set var_ui_password or allow it to be generated)"
  exit 1
fi
SESSION_KEY="$(openssl rand -hex 32)"

{
  printf 'PUBLIC_PORT=%s\n' "$PUBLIC_PORT"
  printf 'MCP_PORT=%s\n' "$PUBLIC_PORT"
  printf 'ADMIN_PORT=%s\n' "$ADMIN_PORT"
  printf 'ADMIN_BIND=%s\n' "$ADMIN_BIND"
  printf 'UI_USER=%s\n' "$UI_USER"
  printf 'UI_PASSWORD=%s\n' "$UI_PASSWORD"
  printf 'AGENTGATEWAY_API_KEY=%s\n' "$API_KEY"
  printf 'SESSION_KEY=%s\n' "$SESSION_KEY"
  printf 'HOME=%s\n' "$INSTALL_DIR"
} >"${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/.env"

write_htpasswd "$UI_USER" "$UI_PASSWORD" "$HTPASSWD_FILE"
write_agentgateway_config "${var_mcp_targets:-}" "${PUBLIC_PORT}" "${ADMIN_ADDR}" "${API_KEY}" "${SESSION_KEY}" "${HTPASSWD_FILE}"

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
validate_out=""
if ! validate_out="$(HOME="${INSTALL_DIR}" /usr/local/bin/agentgateway -f "${INSTALL_DIR}/config.yaml" --validate-only 2>&1)"; then
  echo "${validate_out}"
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
  rc-update add agentgateway default >/dev/null 2>&1
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
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now agentgateway >/dev/null 2>&1
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
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
fi
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
[[ -n "$container_ip" ]] || container_ip="127.0.0.1"

MCP_ENDPOINT="http://${container_ip}:${PUBLIC_PORT}/mcp/http"
UI_URL="http://${container_ip}:${PUBLIC_PORT}/ui"
printf '%s\n' "${MCP_ENDPOINT}" >"${INSTALL_DIR}/mcp_endpoint.txt"
printf '%s\n' "${UI_URL}" >"${INSTALL_DIR}/ui_url.txt"
jq -n --arg url "$MCP_ENDPOINT" --arg token "$API_KEY" \
  '{mcpServers:{agentgateway:{url:$url,headers:{Authorization:("Bearer " + $token)}}}}' \
  >"${INSTALL_DIR}/mcp_client.json"
chmod 600 "${INSTALL_DIR}/mcp_endpoint.txt" "${INSTALL_DIR}/ui_url.txt" "${INSTALL_DIR}/mcp_client.json" "${HTPASSWD_FILE}"
chown agentgateway:agentgateway "${INSTALL_DIR}/mcp_endpoint.txt" "${INSTALL_DIR}/ui_url.txt" "${INSTALL_DIR}/mcp_client.json" "${INSTALL_DIR}/.env" "${INSTALL_DIR}/config.yaml" "${HTPASSWD_FILE}"

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

cleanup_lxc
