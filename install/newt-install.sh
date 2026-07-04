#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/newt

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
  $STD apk add --no-cache curl ca-certificates
  # Alpine dialog package (whiptail), not Pangolin Newt
  $STD apk add --no-cache newt
else
  $STD apt-get install -y curl ca-certificates whiptail
fi
msg_ok "Installed dependencies"

newt_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7* | armhf) arch=arm32 ;;
    riscv64) arch=riscv64 ;;
    *) return 1 ;;
    esac
  fi
  case "$arch" in
  armhf | armel) arch=arm32 ;;
  esac
  echo "$arch"
}

stop_spinner
pangolin_endpoint="${var_pangolin_endpoint:-$(prompt_input "${TAB3}Pangolin endpoint [https://app.pangolin.net]:" "https://app.pangolin.net" 120)}"
newt_id="${var_newt_id:-$(prompt_input "${TAB3}Newt ID (from Pangolin site config):" "" 120)}"
newt_secret="${var_newt_secret:-$(prompt_password "${TAB3}Newt secret:" "" 120)}"

if [[ -z "${newt_id}" || -z "${newt_secret}" || -z "${pangolin_endpoint}" ]]; then
  msg_error "Pangolin endpoint, Newt ID, and Newt secret are required"
  exit 1
fi

ARCH="$(newt_arch)" || {
  msg_error "Unsupported architecture: $(uname -m)"
  exit 1
}

msg_info "Installing Pangolin Newt"
fetch_and_deploy_gh_release "newt" "fosrl/newt" "singlefile" "latest" \
  "/usr/local/bin" "newt_linux_${ARCH}"
msg_ok "Installed Newt binary"

install -d -m 0755 /etc/newt
cat >/etc/newt/newt.env <<EOF
NEWT_ID=${newt_id}
NEWT_SECRET=${newt_secret}
PANGOLIN_ENDPOINT=${pangolin_endpoint}
EOF
chmod 600 /etc/newt/newt.env

msg_info "Setting up Newt service"
if [[ -f /etc/alpine-release ]]; then
  cat >/usr/local/bin/newt-start <<'EOF'
#!/bin/sh
set -a
# shellcheck disable=SC1091
. /etc/newt/newt.env
set +a
exec /usr/local/bin/newt
EOF
  chmod 700 /usr/local/bin/newt-start

  cat >/etc/init.d/newt <<'EOF'
#!/sbin/openrc-run

name="newt"
description="Pangolin Newt tunnel agent"
command="/usr/local/bin/newt-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/newt.log"
error_log="/var/log/newt.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/newt
  $STD rc-update add newt default
  $STD rc-service newt start
else
  cat >/etc/systemd/system/newt.service <<'EOF'
[Unit]
Description=Pangolin Newt
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/newt/newt.env
ExecStart=/usr/local/bin/newt
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $STD systemctl daemon-reload
  $STD systemctl enable --now newt
fi

sleep 2
if [[ -f /etc/alpine-release ]]; then
  if ! rc-service newt status >/dev/null 2>&1; then
    msg_error "Newt service failed to start — check /var/log/newt.log"
    exit 1
  fi
else
  if ! systemctl is-active --quiet newt; then
    msg_error "Newt service failed to start — check: journalctl -u newt"
    exit 1
  fi
fi
msg_ok "Installed ${APPLICATION:-Pangolin Newt}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/newt.sh)"
EOF
chmod +x /usr/bin/update

echo -e "${INFO}${YW} Pangolin endpoint:${CL} ${pangolin_endpoint}"
echo -e "${INFO}${YW} Newt ID:${CL} ${newt_id}"
echo -e "${INFO}${YW} Enable Automatic Site Updates in Pangolin for hands-off binary updates (Newt ≥ 1.13.0).${CL}"

cleanup_lxc
