#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/cli | https://github.com/fosrl/newt

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

configure_pangolin_routing() {
  msg_info "Configuring IPv4 forwarding and NAT masquerade"
  if [[ -f /etc/alpine-release ]]; then
    grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf 2>/dev/null || \
      echo 'net.ipv4.ip_forward=1' >>/etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    $STD apk add --no-cache iptables
    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -j MASQUERADE

    install -d -m 0755 /etc/iptables
    iptables-save >/etc/iptables/iptables.rules
    cat >/etc/local.d/pangolin-site-nat.start <<'EOF'
#!/bin/sh
[ -f /etc/iptables/iptables.rules ] && iptables-restore </etc/iptables/iptables.rules
EOF
    chmod +x /etc/local.d/pangolin-site-nat.start
    rc-update add local default 2>/dev/null || true
  else
    cat >/etc/sysctl.d/99-pangolin-site-routing.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive $STD apt-get install -y -qq iptables-persistent

    iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -j MASQUERADE

    netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
  fi
  msg_ok "Configured IPv4 forwarding and NAT masquerade"
}

configure_pangolin_routing

pangolin_arch() {
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
site_id="${var_site_id:-${var_newt_id:-$(prompt_input "${TAB3}Site ID (from Pangolin site config):" "" 120)}}"
site_secret="${var_site_secret:-${var_newt_secret:-$(prompt_password "${TAB3}Site secret:" "" 120)}}"

if [[ -z "${site_id}" || -z "${site_secret}" || -z "${pangolin_endpoint}" ]]; then
  msg_error "Pangolin endpoint, Site ID, and site secret are required"
  exit 1
fi

ARCH="$(pangolin_arch)" || {
  msg_error "Unsupported architecture: $(uname -m)"
  exit 1
}

msg_info "Installing Pangolin CLI (site mode)"
fetch_and_deploy_gh_release "pangolin-cli" "fosrl/cli" "singlefile" "latest" \
  "/usr/local/bin" "pangolin-cli_linux_${ARCH}"
msg_ok "Installed Pangolin CLI binary"

install -d -m 0755 /etc/pangolin
cat >/etc/pangolin/pangolin-site.env <<EOF
SITE_ID=${site_id}
SITE_SECRET=${site_secret}
PANGOLIN_ENDPOINT=${pangolin_endpoint}
EOF
chmod 600 /etc/pangolin/pangolin-site.env

cat >/usr/local/bin/pangolin-site-start <<'EOF'
#!/bin/sh
set -a
if [ -f /etc/pangolin/pangolin-site.env ]; then
  . /etc/pangolin/pangolin-site.env
fi
# `pangolin up site` is Newt embedded in the CLI and honors the same NEWT_*
# vars as the standalone binary, alongside the SITE_* aliases. Export both.
export NEWT_ID="${SITE_ID:-${NEWT_ID:-}}"
export NEWT_SECRET="${SITE_SECRET:-${NEWT_SECRET:-}}"
set +a
exec /usr/local/bin/pangolin-cli up site
EOF
chmod 700 /usr/local/bin/pangolin-site-start

msg_info "Setting up Pangolin Site service"
if [[ -f /etc/alpine-release ]]; then
  cat >/etc/init.d/pangolin-site <<'EOF'
#!/sbin/openrc-run

name="pangolin-site"
description="Pangolin Site connector (CLI)"
command="/usr/local/bin/pangolin-site-start"
command_background=true
command_user=root
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/pangolin-site.log"
error_log="/var/log/pangolin-site.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/pangolin-site
  $STD rc-update add pangolin-site default
  $STD rc-service pangolin-site start
else
  cat >/etc/systemd/system/pangolin-site.service <<'EOF'
[Unit]
Description=Pangolin Site (CLI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/pangolin/pangolin-site.env
ExecStart=/usr/local/bin/pangolin-site-start
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  $STD systemctl daemon-reload
  $STD systemctl enable --now pangolin-site
fi

sleep 2
if [[ -f /etc/alpine-release ]]; then
  if ! rc-service pangolin-site status >/dev/null 2>&1; then
    msg_error "Pangolin Site service failed to start — check /var/log/pangolin-site.log"
    exit 1
  fi
else
  if ! systemctl is-active --quiet pangolin-site; then
    msg_error "Pangolin Site service failed to start — check: journalctl -u pangolin-site"
    exit 1
  fi
fi
msg_ok "Installed ${APPLICATION:-Pangolin Site}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/pangolin-site.sh)"
EOF
chmod +x /usr/bin/update

echo -e "${INFO}${YW} Pangolin endpoint:${CL} ${pangolin_endpoint}"
echo -e "${INFO}${YW} Site ID:${CL} ${site_id}"
echo -e "${INFO}${YW} Update the CLI binary: /usr/bin/update (or enable Automatic Site Updates in the Pangolin dashboard).${CL}"

cleanup_lxc
