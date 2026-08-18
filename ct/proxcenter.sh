#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.proxcenter.io/ | Github: https://github.com/adminsyspro/proxcenter-ui

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
source <(curl -fsSL "${REPO_RAW}/misc/build.func")

APP="ProxCenter"
NSAPP="proxcenter"
var_tags="${var_tags:-proxmox;management;proxcenter}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-12}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-proxcenter}"
apply_debian13_lxc_defaults
apply_alpine_lxc_defaults
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
NSAPP="proxcenter"
var_install="proxcenter-install"
var_hostname="${var_hostname:-proxcenter}"
color
catch_errors

function proxcenter_primary_ipv4() {
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

function proxcenter_show_url() {
  local ip edition
  ip="$(proxcenter_primary_ipv4)"
  edition="community"
  if [[ -f /opt/proxcenter/edition ]]; then
    edition="$(tr -d '[:space:]' </opt/proxcenter/edition)"
  elif [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1; then
    edition="$(pct exec "$CTID" -- cat /opt/proxcenter/edition 2>/dev/null || true)"
    edition="$(printf '%s' "$edition" | tr -d '[:space:]')"
  fi
  [[ -n "$edition" ]] || edition="${var_edition:-community}"
  echo -e "${INFO}${YW} Access ProxCenter (${edition}) at:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${ip}:3000${CL}"
  echo -e "${INFO}${YW} First visit:${CL} create the initial admin account in the web UI, then add Proxmox VE (and optional PBS) connections with API tokens."
}

function proxcenter_is_silent() {
  if declare -f is_unattended >/dev/null 2>&1 && is_unattended; then
    return 0
  fi
  [[ "${PHS_SILENT:-0}" == "1" ]] && return 0
  [[ "${var_unattended:-}" =~ ^(yes|true|1)$ ]] && return 0
  [[ "${UNATTENDED:-}" =~ ^(yes|true|1)$ ]] && return 0
  [[ ! -t 0 ]] && return 0
  return 1
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/proxcenter/docker-compose.yml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  UPD=$(msg_menu "ProxCenter Update Options" \
    "1" "Update ProxCenter" \
    "2" "Remove Unused Images")

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
    cd /opt/proxcenter || exit
    image_tag="$(grep '^VERSION=' /opt/proxcenter/.env 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [[ -n "$image_tag" ]] || image_tag="latest"
    $STD docker compose pull
    $STD docker compose up -d
    docker inspect "ghcr.io/adminsyspro/proxcenter-frontend:${image_tag}" --format='{{index .RepoDigests 0}}' 2>/dev/null \
      | awk -F@ '{print $2}' >/opt/proxcenter/proxcenter_version.txt || true
    msg_ok "Updated ${APP}"

    msg_ok "Updated successfully!"
    proxcenter_show_url
    exit
  fi

  if [[ "$UPD" == "2" ]]; then
    msg_info "Removing unused images"
    $STD docker image prune -af
    msg_ok "Removed unused images"
    exit
  fi
}

function prompt_proxcenter_edition() {
  var_edition="${var_edition:-}"
  var_edition="${var_edition,,}"
  var_image_version="${var_image_version:-latest}"
  var_install_token="${var_install_token:-}"
  var_license_key="${var_license_key:-}"
  var_nextauth_url="${var_nextauth_url:-}"

  if [[ -z "$var_edition" ]]; then
    if proxcenter_is_silent; then
      var_edition="community"
    else
      command -v stop_spinner >/dev/null 2>&1 && stop_spinner
      local choice="1"
      if command -v whiptail >/dev/null 2>&1; then
        if ! choice=$(whiptail --backtitle "Proxmox Custom Scripts" \
          --title "PROXCENTER EDITION" \
          --ok-button "Next" --cancel-button "Exit" \
          --menu "\nChoose the ProxCenter edition to install" 14 70 2 \
          "1" "Community (free) — inventory, backups, storage" \
          "2" "Enterprise — DRS, RBAC, orchestrator (install token required)" \
          3>&1 1>&2 2>&3); then
          if declare -f exit_script >/dev/null 2>&1; then
            exit_script
          fi
          exit 1
        fi
      fi
      case "$choice" in
      2) var_edition="enterprise" ;;
      *) var_edition="community" ;;
      esac
    fi
  fi

  case "$var_edition" in
  community | enterprise) ;;
  *)
    msg_error "var_edition must be community or enterprise"
    exit 1
    ;;
  esac

  if [[ "$var_edition" == "enterprise" && -z "$var_install_token" ]]; then
    if proxcenter_is_silent; then
      msg_error "Unattended Enterprise install requires var_install_token"
      exit 1
    fi
    command -v stop_spinner >/dev/null 2>&1 && stop_spinner
    local result=""
    if command -v whiptail >/dev/null 2>&1; then
      while true; do
        if ! result=$(whiptail --backtitle "Proxmox Custom Scripts" \
          --title "PROXCENTER INSTALL TOKEN" \
          --ok-button "Next" --cancel-button "Exit" \
          --passwordbox "\nEnterprise install token\n(from https://proxcenter.io/account)" 12 70 \
          3>&1 1>&2 2>&3); then
          if declare -f exit_script >/dev/null 2>&1; then
            exit_script
          fi
          exit 1
        fi
        if [[ -n "$result" ]]; then
          var_install_token="$result"
          break
        fi
        whiptail --msgbox "An Enterprise install token is required." 8 58
      done
      result=$(whiptail --backtitle "Proxmox Custom Scripts" \
        --title "PROXCENTER LICENSE (OPTIONAL)" \
        --ok-button "Next" --cancel-button "Skip" \
        --inputbox "\nLicense key (optional — can be activated later in Settings → License)" 12 70 \
        "${var_license_key:-}" \
        3>&1 1>&2 2>&3) || result=""
      var_license_key="$result"
    else
      var_install_token="$(prompt_password "${TAB3}ProxCenter Enterprise install token:" "" 120)"
      if [[ -z "$var_install_token" ]]; then
        msg_error "Enterprise install token is required"
        exit 1
      fi
      var_license_key="${var_license_key:-$(prompt_input "${TAB3}License key (optional, leave empty to skip):" "" 120)}"
    fi
  fi

  export var_edition var_image_version var_install_token var_license_key var_nextauth_url
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
prompt_proxcenter_edition
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
proxcenter_show_url
