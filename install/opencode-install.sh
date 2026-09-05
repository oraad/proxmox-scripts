#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://opencode.ai/ | Github: https://github.com/anomalyco/opencode

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/root/.config/opencode}"
OPENCODE_ENV_FILE="${OPENCODE_ENV_FILE:-/etc/opencode/opencode.env}"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing update menu dependencies"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache newt
else
  $STD apt-get install -y whiptail
fi
msg_ok "Installed update menu dependencies"

msg_info "Installing dependencies"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache curl ca-certificates openssl tar
else
  $STD apt-get install -y curl ca-certificates openssl
fi
msg_ok "Installed dependencies"

# Add the opencode binary dir to PATH for logins (installer ran with
# --no-modify-path so it does not touch per-user shell configs).
cat >/etc/profile.d/opencode.sh <<EOF
export PATH="/root/.opencode/bin:\$PATH"
EOF

stop_spinner
msg_info "Installing ${APPLICATION:-OpenCode Server}"
$STD bash -c 'curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path'
if [[ ! -x "$OPENCODE_BIN" ]]; then
  msg_error "OpenCode binary not found at ${OPENCODE_BIN}"
  exit 1
fi
OPENCODE_VERSION="$("$OPENCODE_BIN" --version 2>/dev/null || echo "unknown")"
msg_ok "Installed ${APPLICATION:-OpenCode Server} (${OPENCODE_VERSION})"

msg_info "Configuring ${APPLICATION:-OpenCode Server}"
mkdir -p "$OPENCODE_CONFIG_DIR"
if [[ ! -f "${OPENCODE_CONFIG_DIR}/config.json" ]]; then
  cat >"${OPENCODE_CONFIG_DIR}/config.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": true,
  "server": {
    "port": ${OPENCODE_PORT},
    "hostname": "0.0.0.0"
  }
}
EOF
fi

# Generate a one-time shown password for HTTP basic auth.
OPENCODE_PASSWORD="${var_opencode_password:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"
mkdir -p "$(dirname "$OPENCODE_ENV_FILE")"
cat >"$OPENCODE_ENV_FILE" <<EOF
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=${OPENCODE_PASSWORD}
EOF
chmod 600 "$OPENCODE_ENV_FILE"
msg_ok "Configured ${APPLICATION:-OpenCode Server}"

msg_info "Setting up OpenCode service"
if [[ -f /etc/alpine-release ]]; then
  cat >/usr/local/bin/opencode-start <<'EOF'
#!/bin/sh
set -a
# shellcheck disable=SC1091
. /etc/opencode/opencode.env
set +a
exec /root/.opencode/bin/opencode web --hostname 0.0.0.0 --port 4096
EOF
  chmod 700 /usr/local/bin/opencode-start

  cat >/etc/init.d/opencode <<'EOF'
#!/sbin/openrc-run

name="opencode"
description="OpenCode server (web UI)"
command="/usr/local/bin/opencode-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/opencode.log"
error_log="/var/log/opencode.log"

depend() {
    need net
}
EOF
  chmod +x /etc/init.d/opencode
  $STD rc-update add opencode default
  $STD rc-service opencode start
else
  cat >/etc/systemd/system/opencode.service <<'EOF'
[Unit]
Description=OpenCode server (web UI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/opencode/opencode.env
ExecStart=/root/.opencode/bin/opencode web --hostname 0.0.0.0 --port 4096
Restart=always
RestartSec=3
WorkingDirectory=/root
UMask=0022
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $STD systemctl daemon-reload
  $STD systemctl enable --now opencode
fi

sleep 2
if [[ -f /etc/alpine-release ]]; then
  if ! rc-service opencode status >/dev/null 2>&1; then
    msg_error "OpenCode service failed to start — check /var/log/opencode.log"
    exit 1
  fi
else
  if ! systemctl is-active --quiet opencode; then
    msg_error "OpenCode service failed to start — check: journalctl -u opencode"
    exit 1
  fi
fi
msg_ok "Installed ${APPLICATION:-OpenCode Server}"

echo -e "${INFO}${YW} Web UI username (HTTP Basic):${CL} opencode"
echo -e "${INFO}${YW} Generated password (shown once):${CL} ${OPENCODE_PASSWORD}"
echo -e "${INFO}${YW} Saved to:${CL} ${OPENCODE_ENV_FILE} (mode 0600)"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/opencode.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc