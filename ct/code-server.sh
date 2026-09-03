#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://coder.com/ | Github: https://github.com/coder/code-server

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="Coder Code Server"
var_tags="${var_tags:-code;vscode;dev;coder;codeserver}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
color
catch_errors

function code_server_primary_ipv4() {
  local ip="${LOCAL_IP:-${IP:-}}"
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

function code_server_show_url() {
  local ip
  ip="$(code_server_primary_ipv4)"
  echo -e "${INFO}${YW} Access Code Server at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${ip}:8680${CL}"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x "$(command -v code-server)" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "${APP} Update Options" \
    "1" "Update ${APP}" \
    "2" "Remove Unused Packages" \
    "3" "Restart ${APP}")

  if [[ "$UPD" == "1" ]]; then
    msg_info "Updating base system"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk -U upgrade
    else
      $STD apt update
      $STD apt -y upgrade
    fi
    msg_ok "Base system updated"

    msg_info "Updating ${APP}"
    local version arch
    version=$(curl -fsSL https://api.github.com/repos/coder/code-server/releases/latest | grep '"tag_name"' | awk -F'"' '{print $4}')
    version="${version#v}"
    case "$(dpkg --print-architecture 2>/dev/null)" in
      arm64 | aarch64) arch="arm64" ;;
      *) arch="amd64" ;;
    esac
    curl -fOL "https://github.com/coder/code-server/releases/download/v${version}/code-server_${version}_${arch}.deb" \
      && dpkg -i code-server_"${version}"_"${arch}".deb >/dev/null 2>&1 \
      && rm -f code-server_"${version}"_"${arch}".deb
    systemctl restart "code-server@${SUDO_USER:-${USER:-root}}" 2>/dev/null || systemctl restart code-server@root 2>/dev/null || true
    msg_ok "Updated ${APP} to v${version}"

    msg_ok "Updated successfully!"
    code_server_show_url
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused packages"
    if [[ -f /etc/alpine-release ]]; then
      $STD apk cache clean
    else
      $STD apt autoremove -y
      $STD apt clean
    fi
    msg_ok "Removed unused packages"
    exit
  fi

  if [[ "$UPD" == "3" ]]; then
    msg_info "Restarting ${APP}"
    systemctl restart "code-server@${SUDO_USER:-${USER:-root}}" 2>/dev/null || systemctl restart code-server@root 2>/dev/null || true
    msg_ok "Restarted ${APP}"
    code_server_show_url
    exit
  fi
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
code_server_show_url
