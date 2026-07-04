#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/oraad/solar-ai-optimizer

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing update menu dependencies"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache newt openssl
else
  $STD apt-get install -y whiptail openssl
fi
msg_ok "Installed update menu dependencies"

# shellcheck disable=SC1090
source <(curl -fsSL "${REPO_RAW}/misc/solar-common.sh")

solar_install_docker

msg_info "Pulling ${APP:-Solar AI Optimizer} image"
$STD docker pull "$(solar_image_ref)"
msg_ok "Pulled image $(solar_image_ref)"

msg_info "Configuring ${APP:-Solar AI Optimizer}"
solar_write_env_file
msg_info "Starting ${APP:-Solar AI Optimizer}"
solar_ensure_data_volume
$STD solar_run_container
solar_save_version
msg_ok "Started ${APP:-Solar AI Optimizer}"

msg_info "Waiting for health check"
if solar_wait_healthy 127.0.0.1 "$SOLAR_PORT" "$SOLAR_HEALTH_PATH" 120; then
  msg_ok "Service is healthy"
else
  msg_warn "Health check timed out — the container may still be starting"
  msg_warn "Check logs: docker logs ${SOLAR_CONTAINER}"
fi

solar_show_admin_credentials

solar_install_reset_script

motd_ssh
customize
solar_write_update_command
cleanup_lxc
