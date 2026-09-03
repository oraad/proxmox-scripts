#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://coder.com/ | Github: https://github.com/coder/code-server

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -f /etc/alpine-release ]]; then
  msg_error "code-server ships Debian/Ubuntu packages only — use the default (Debian 13) template."
  exit 1
fi

msg_info "Installing update menu dependencies"
$STD apt-get install -y whiptail
msg_ok "Installed update menu dependencies"

msg_info "Installing Dependencies"
$STD apt-get install -y curl git jq
msg_ok "Installed Dependencies"

msg_info "Installing ${APPLICATION:-Coder Code Server}"

VERSION=$(curl -fsSL https://api.github.com/repos/coder/code-server/releases/latest | grep '"tag_name"' | awk -F'"' '{print $4}')
VERSION="${VERSION#v}"

ARCH="amd64"
case "$(dpkg --print-architecture 2>/dev/null)" in
  arm64 | aarch64) ARCH="arm64" ;;
esac

mkdir -p "$HOME/.config/code-server/"

curl -fOL "https://github.com/coder/code-server/releases/download/v${VERSION}/code-server_${VERSION}_${ARCH}.deb"
$STD dpkg -i "code-server_${VERSION}_${ARCH}.deb"
rm -f "code-server_${VERSION}_${ARCH}.deb"

if [[ ! -f "$HOME/.config/code-server/config.yaml" ]]; then
  cat <<EOF >"$HOME/.config/code-server/config.yaml"
bind-addr: 0.0.0.0:8680
auth: none
cert: false
EOF
fi

systemctl enable -q --now "code-server@${USER:-root}" 2>/dev/null || systemctl enable -q --now code-server@root || true
systemctl restart "code-server@${USER:-root}" 2>/dev/null || systemctl restart code-server@root 2>/dev/null || true

if ! systemctl is-active --quiet "code-server@${USER:-root}" 2>/dev/null \
  && ! systemctl is-active --quiet code-server@root 2>/dev/null; then
  msg_error "code-server service failed to start."
  exit 150
fi

msg_ok "Installed ${APPLICATION:-Coder Code Server} v${VERSION}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/code-server.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc
