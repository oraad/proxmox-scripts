#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://agentgateway.dev/docs/standalone/latest/ | Github: https://github.com/agentgateway/agentgateway

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Agent Gateway"
NSAPP="agentgateway"
var_tags="${var_tags:-mcp;ai;gateway;agentgateway}"
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
NSAPP="agentgateway"
var_install="agentgateway-install"
color
catch_errors

function agentgateway_arch() {
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

function agentgateway_stop_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service agentgateway stop || true
  else
    $STD systemctl stop agentgateway || true
  fi
}

function agentgateway_start_service() {
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service agentgateway start
  else
    $STD systemctl start agentgateway
  fi
}

function agentgateway_container_ip() {
  local ip="${IP:-}"
  if [[ -z "$ip" || "$ip" == "127.0.0.1" || "$ip" == "Unknown" ]]; then
    if declare -f get_current_ip >/dev/null 2>&1; then
      ip="$(get_current_ip)"
    else
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
  fi
  [[ -n "$ip" ]] || ip="127.0.0.1"
  echo "$ip"
}

function agentgateway_ports() {
  local mcp_port admin_port env_line
  mcp_port="${MCP_PORT:-3000}"
  admin_port="${ADMIN_PORT:-15000}"
  if [[ -f /opt/agentgateway/.env ]]; then
    # shellcheck disable=SC1091
    set -a
    source /opt/agentgateway/.env
    set +a
    mcp_port="${MCP_PORT:-3000}"
    admin_port="${ADMIN_PORT:-15000}"
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    env_line="$(pct exec "$CTID" -- bash -c 'set -a; . /opt/agentgateway/.env; printf "%s %s" "${MCP_PORT:-3000}" "${ADMIN_PORT:-15000}"' 2>/dev/null || true)"
    if [[ -n "$env_line" ]]; then
      mcp_port="${env_line%% *}"
      admin_port="${env_line##* }"
    fi
  fi
  echo "${mcp_port} ${admin_port}"
}

function agentgateway_env_value() {
  local key="$1" line=""
  if [[ ! "$key" =~ ^[A-Z_]+$ ]]; then
    return 0
  fi
  if [[ -f /opt/agentgateway/.env ]]; then
    line="$(grep -m1 "^${key}=" /opt/agentgateway/.env || true)"
    printf '%s' "${line#*=}"
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    line="$(pct exec "$CTID" -- grep -m1 "^${key}=" /opt/agentgateway/.env 2>/dev/null || true)"
    printf '%s' "${line#*=}"
  fi
}

function agentgateway_show_endpoints() {
  local ip mcp_port admin_port admin_bind mcp_url ui_url api_key
  ip="$(agentgateway_container_ip)"
  read -r mcp_port admin_port <<<"$(agentgateway_ports)"
  admin_bind="$(agentgateway_env_value ADMIN_BIND)"
  [[ -n "$admin_bind" ]] || admin_bind="127.0.0.1"
  api_key="$(agentgateway_env_value AGENTGATEWAY_API_KEY)"
  mcp_url="http://${ip}:${mcp_port}/mcp/http"
  if [[ "$admin_bind" == "127.0.0.1" || "$admin_bind" == "localhost" ]]; then
    ui_url="http://127.0.0.1:${admin_port}/ui"
  else
    ui_url="http://${ip}:${admin_port}/ui"
  fi
  if [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1 && [[ ! -f /opt/agentgateway/.env ]]; then
    pct exec "$CTID" -- bash -c "printf '%s\n' '$mcp_url' >/opt/agentgateway/mcp_endpoint.txt; printf '%s\n' '$ui_url' >/opt/agentgateway/ui_url.txt" 2>/dev/null || true
  elif [[ -d /opt/agentgateway ]]; then
    printf '%s\n' "$mcp_url" >/opt/agentgateway/mcp_endpoint.txt
    printf '%s\n' "$ui_url" >/opt/agentgateway/ui_url.txt
  fi
  echo -e "${INFO}${YW} MCP endpoint (Cursor):${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}${mcp_url}${CL}"
  if [[ -n "$api_key" ]]; then
    echo -e "${INFO}${YW} Authorization:${CL} Bearer ${api_key}"
  fi
  echo -e "${INFO}${YW} Admin UI:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}${ui_url}${CL}"
  if [[ "$admin_bind" == "127.0.0.1" || "$admin_bind" == "localhost" ]]; then
    echo -e "${INFO}${YW} Admin UI is loopback-only. Tunnel: \`ssh -L 15000:127.0.0.1:15000 root@${ip}\`${CL}"
  fi
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/agentgateway/config.yaml ]]; then
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

  local arch
  if ! arch="$(agentgateway_arch)"; then
    msg_error "Unsupported architecture: $(uname -m) (need amd64 or arm64)"
    exit
  fi

  if check_for_gh_release "agentgateway" "agentgateway/agentgateway"; then
    msg_info "Stopping ${APP}"
    agentgateway_stop_service
    msg_ok "Stopped ${APP}"

    fetch_and_deploy_gh_release "agentgateway" "agentgateway/agentgateway" "singlefile" "latest" \
      "/usr/local/bin" "agentgateway-linux-${arch}"

    msg_info "Starting ${APP}"
    agentgateway_start_service
    msg_ok "Started ${APP}"
    msg_ok "Updated successfully!"
  fi

  agentgateway_show_endpoints
  exit
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
agentgateway_show_endpoints
api_key="$(agentgateway_env_value AGENTGATEWAY_API_KEY)"
mcp_port="$(agentgateway_ports)"
mcp_port="${mcp_port%% *}"
echo -e "${INFO}${YW} Add to Cursor (~/.cursor/mcp.json):${CL}"
if [[ -n "$api_key" ]]; then
  echo -e "${TAB}{ \"mcpServers\": { \"agentgateway\": { \"url\": \"http://$(agentgateway_container_ip):${mcp_port}/mcp/http\", \"headers\": { \"Authorization\": \"Bearer ${api_key}\" } } } }"
else
  echo -e "${TAB}{ \"mcpServers\": { \"agentgateway\": { \"url\": \"http://$(agentgateway_container_ip):${mcp_port}/mcp/http\" } } }"
fi
