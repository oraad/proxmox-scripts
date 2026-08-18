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

function ha_mcp_primary_ipv4() {
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

function ha_mcp_endpoint_url() {
  local ip path port env_line
  ip="$(ha_mcp_primary_ipv4)"
  path="/mcp"
  port="8086"
  if [[ -f /opt/ha-mcp/.env ]]; then
    # shellcheck disable=SC1091
    set -a
    source /opt/ha-mcp/.env
    set +a
    path="${MCP_SECRET_PATH:-/mcp}"
    port="${MCP_PORT:-8086}"
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    env_line="$(pct exec "$CTID" -- bash -c 'set -a; . /opt/ha-mcp/.env; printf "%s %s" "${MCP_SECRET_PATH:-/mcp}" "${MCP_PORT:-8086}"' 2>/dev/null || true)"
    if [[ -n "$env_line" ]]; then
      path="${env_line%% *}"
      port="${env_line##* }"
    fi
  fi
  [[ -n "$path" ]] || path="/mcp"
  [[ -n "$port" ]] || port="8086"
  echo "http://${ip}:${port}${path}"
}

function ha_mcp_show_endpoint() {
  local endpoint
  endpoint="$(ha_mcp_endpoint_url)"
  if [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1 && [[ ! -f /opt/ha-mcp/.env ]]; then
    pct exec "$CTID" -- bash -c "printf '%s\n' '$endpoint' >/opt/ha-mcp/mcp_endpoint.txt" 2>/dev/null || true
    pct exec "$CTID" -- tee /opt/ha-mcp/mcp_client.json >/dev/null <<EOF
{
  "mcpServers": {
    "home-assistant": {
      "url": "${endpoint}"
    }
  }
}
EOF
    pct exec "$CTID" -- chmod 600 /opt/ha-mcp/mcp_endpoint.txt /opt/ha-mcp/mcp_client.json 2>/dev/null || true
  elif [[ -f /opt/ha-mcp/.env ]]; then
    printf '%s\n' "$endpoint" >/opt/ha-mcp/mcp_endpoint.txt
  fi
  echo -e "${INFO}${YW} MCP:${CL} ${GATEWAY}${BGN}${endpoint}${CL}"
  echo -e "${INFO}${YW} MCP client config:${CL}"
  cat <<EOF
{
  "mcpServers": {
    "home-assistant": {
      "url": "${endpoint}"
    }
  }
}
EOF
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
  cat >"/opt/ha-mcp/start.sh" <<EOF
#!/bin/sh
set -a
. /opt/ha-mcp/.env
set +a
exec ${UVX_PATH} --python 3.14 --from ha-mcp@latest ha-mcp-web
EOF
  chmod 700 /opt/ha-mcp/start.sh
  $STD "$UVX_PATH" --python 3.14 --refresh ha-mcp@latest --version
  if [[ -f /etc/alpine-release ]]; then
    $STD rc-service ha-mcp restart
  else
    $STD systemctl restart ha-mcp
  fi
  msg_ok "Updated ${APP}"

  msg_ok "Updated successfully!"
  ha_mcp_show_endpoint
  exit
}

function prompt_ha_credentials() {
  if [[ -n "${var_ha_url:-}" && -n "${var_ha_token:-}" ]]; then
    export var_ha_url var_ha_token
    return 0
  fi

  local silent=0
  [[ "${PHS_SILENT:-0}" == "1" ]] && silent=1
  [[ "${var_unattended:-}" =~ ^(yes|true|1)$ ]] && silent=1
  [[ "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] && silent=1
  [[ ! -t 0 ]] && silent=1

  if [[ "$silent" -eq 1 ]]; then
    msg_error "Unattended install requires var_ha_url and var_ha_token"
    exit 1
  fi

  command -v stop_spinner >/dev/null 2>&1 && stop_spinner

  if ! command -v whiptail >/dev/null 2>&1; then
    var_ha_url="${var_ha_url:-$(prompt_input "${TAB3}Home Assistant URL [http://homeassistant.local:8123]:" "http://homeassistant.local:8123" 120)}"
    var_ha_token="${var_ha_token:-$(prompt_password "${TAB3}Home Assistant long-lived access token:" "" 120)}"
    if [[ -z "${var_ha_token}" ]]; then
      msg_error "HOMEASSISTANT_TOKEN is required"
      exit 1
    fi
    export var_ha_url var_ha_token
    return 0
  fi

  local result
  while true; do
    if ! result=$(whiptail --backtitle "Proxmox Custom Scripts" \
      --title "HOME ASSISTANT URL" \
      --ok-button "Next" --cancel-button "Exit" \
      --inputbox "\nHome Assistant URL\n(e.g. http://192.168.1.10:8123)" 12 70 \
      "${var_ha_url:-http://homeassistant.local:8123}" \
      3>&1 1>&2 2>&3); then
      if declare -f exit_script >/dev/null 2>&1; then
        exit_script
      fi
      exit 1
    fi
    result="${result%"${result##*[![:space:]]}"}"
    result="${result#"${result%%[![:space:]]*}"}"
    if [[ "$result" =~ ^https?://[^[:space:]]+$ ]]; then
      var_ha_url="$result"
      break
    fi
    whiptail --msgbox "Enter a valid http:// or https:// URL.\nExample: http://192.168.1.10:8123" 10 58
  done

  while true; do
    if ! result=$(whiptail --backtitle "Proxmox Custom Scripts" \
      --title "HOME ASSISTANT TOKEN" \
      --ok-button "Next" --cancel-button "Exit" \
      --passwordbox "\nLong-lived access token\n(HA Profile → Security → Create Token)" 12 70 \
      3>&1 1>&2 2>&3); then
      if declare -f exit_script >/dev/null 2>&1; then
        exit_script
      fi
      exit 1
    fi
    if [[ -n "$result" ]]; then
      var_ha_token="$result"
      break
    fi
    whiptail --msgbox "A Home Assistant long-lived access token is required." 8 58
  done

  export var_ha_url var_ha_token
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
prompt_ha_credentials
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
ha_mcp_show_endpoint
