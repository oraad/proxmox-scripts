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
var_hostname="${var_hostname:-agent-gateway}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="agentgateway"
var_install="agentgateway-install"
var_hostname="${var_hostname:-agent-gateway}"
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

function agentgateway_primary_ipv4() {
  local ip="${IP:-}"
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

function agentgateway_container_ip() {
  agentgateway_primary_ipv4
}

function agentgateway_ports() {
  local public_port env_line
  public_port="${PUBLIC_PORT:-${MCP_PORT:-8080}}"
  if [[ -f /opt/agentgateway/.env ]]; then
    # shellcheck disable=SC1091
    set -a
    source /opt/agentgateway/.env
    set +a
    public_port="${PUBLIC_PORT:-${MCP_PORT:-8080}}"
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    env_line="$(pct exec "$CTID" -- bash -c 'set -a; . /opt/agentgateway/.env; printf "%s" "${PUBLIC_PORT:-${MCP_PORT:-8080}}"' 2>/dev/null || true)"
    if [[ -n "$env_line" ]]; then
      public_port="$env_line"
    fi
  fi
  echo "${public_port}"
}

function agentgateway_env_value() {
  local key="$1"
  if [[ ! "$key" =~ ^[A-Z_]+$ ]]; then
    return 0
  fi
  if [[ -f /opt/agentgateway/.env ]]; then
    (
      set -a
      # shellcheck disable=SC1091
      source /opt/agentgateway/.env
      set +a
      eval "printf '%s' \"\${${key}:-}\""
    )
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    pct exec "$CTID" -- bash -c "set -a; . /opt/agentgateway/.env; printf '%s' \"\${${key}:-}\"" 2>/dev/null || true
  fi
}

function agentgateway_show_endpoints() {
  local ip public_port mcp_url ui_url api_key ui_user ui_password
  ip="$(agentgateway_container_ip)"
  public_port="$(agentgateway_ports)"
  api_key="$(agentgateway_env_value AGENTGATEWAY_API_KEY)"
  ui_user="$(agentgateway_env_value UI_USER)"
  ui_password="$(agentgateway_env_value UI_PASSWORD)"
  [[ -n "$ui_user" ]] || ui_user="admin"
  mcp_url="http://${ip}:${public_port}/mcp/http"
  ui_url="http://${ip}:${public_port}/ui"
  if [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1 && [[ ! -f /opt/agentgateway/.env ]]; then
    pct exec "$CTID" -- bash -c "printf '%s\n' '$mcp_url' >/opt/agentgateway/mcp_endpoint.txt; printf '%s\n' '$ui_url' >/opt/agentgateway/ui_url.txt" 2>/dev/null || true
    if [[ -n "$api_key" ]]; then
      pct exec "$CTID" -- tee /opt/agentgateway/mcp_client.json >/dev/null <<EOF
{
  "mcpServers": {
    "agentgateway": {
      "url": "${mcp_url}",
      "headers": {
        "Authorization": "Bearer ${api_key}"
      }
    }
  }
}
EOF
      pct exec "$CTID" -- chown agentgateway:agentgateway /opt/agentgateway/mcp_endpoint.txt /opt/agentgateway/ui_url.txt /opt/agentgateway/mcp_client.json 2>/dev/null || true
    fi
  elif [[ -d /opt/agentgateway ]]; then
    printf '%s\n' "$mcp_url" >/opt/agentgateway/mcp_endpoint.txt
    printf '%s\n' "$ui_url" >/opt/agentgateway/ui_url.txt
    if [[ -n "$api_key" ]]; then
      jq -n --arg url "$mcp_url" --arg token "$api_key" \
        '{mcpServers:{agentgateway:{url:$url,headers:{Authorization:("Bearer " + $token)}}}}' \
        >/opt/agentgateway/mcp_client.json 2>/dev/null || true
    fi
  fi
  echo -e "${INFO}${YW} MCP:${CL} ${GATEWAY}${BGN}${mcp_url}${CL}"
  if [[ -n "$api_key" ]]; then
    echo -e "${INFO}${YW} API key:${CL} ${api_key}"
  else
    echo -e "${INFO}${YW} API key:${CL} \`pct exec ${CTID:-<CTID>} -- grep AGENTGATEWAY_API_KEY /opt/agentgateway/.env\`${CL}"
  fi
  echo -e "${INFO}${YW} UI:${CL} ${GATEWAY}${BGN}${ui_url}${CL}"
  echo -e "${INFO}${YW} UI user:${CL} ${ui_user}"
  if [[ -n "$ui_password" ]]; then
    echo -e "${INFO}${YW} UI password:${CL} ${ui_password}"
  else
    echo -e "${INFO}${YW} UI password:${CL} \`pct exec ${CTID:-<CTID>} -- grep UI_PASSWORD /opt/agentgateway/.env\`${CL}"
  fi
  echo -e "${INFO}${YW} Auth:${CL} UI requires HTTP basic auth. MCP accepts Bearer API key or the same basic-auth credentials."
  echo -e "${INFO}${YW} MCP client config:${CL}"
  if [[ -n "$api_key" ]]; then
    cat <<EOF
{
  "mcpServers": {
    "agentgateway": {
      "url": "${mcp_url}",
      "headers": {
        "Authorization": "Bearer ${api_key}"
      }
    }
  }
}
EOF
  else
    echo -e "${TAB}See /opt/agentgateway/mcp_client.json inside the container."
  fi
  echo -e "${INFO}${YW} Add backends:${CL} UI → MCP → Servers, or /opt/agentgateway/config.yaml"
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
