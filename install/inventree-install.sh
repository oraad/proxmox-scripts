#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://inventree.org/ | Github: https://github.com/inventree/InvenTree

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing update menu dependencies"
$STD apt-get install -y whiptail
msg_ok "Installed update menu dependencies"

msg_info "Installing dependencies"
$STD apt-get install -y curl ca-certificates openssl
msg_ok "Installed dependencies"

function inventree_primary_ipv4() {
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

# Generate credentials before the package install - the packager post-install
# script reads these from the environment (SETUP_ENVS whitelist) to create the
# InvenTree admin account.
admin_user="${var_admin_user:-admin}"
admin_email="${var_admin_email:-admin@inventree.local}"
admin_password="${var_admin_password:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

CT_IP="$(inventree_primary_ipv4)"
site_url="${var_site_url:-http://${CT_IP}}"

msg_info "Adding InvenTree apt repository"
$STD curl -fsSL "https://go.packager.io/srv/deb/inventree/InvenTree/gpg-key.gpg" -o /usr/share/keyrings/InvenTree.gpg
$STD curl -fsSL "https://go.packager.io/srv/inventree/InvenTree/stable/installer/debian/13.list" -o /etc/apt/sources.list.d/inventree.list
$STD apt-get update
msg_ok "Added InvenTree apt repository"

msg_info "Installing ${APPLICATION:-InvenTree} (package setup runs migrations, may take 5-10 minutes)"
stop_spinner
if ! $STD env SETUP_NO_CALLS=true INVENTREE_SITE_URL="${site_url}" INVENTREE_ADMIN_USER="${admin_user}" INVENTREE_ADMIN_EMAIL="${admin_email}" INVENTREE_ADMIN_PASSWORD="${admin_password}" apt-get install -y inventree; then
  msg_error "InvenTree package installation failed"
  exit 1
fi
if ! dpkg-query -W -f='${Status}' inventree 2>/dev/null | grep -q "ok installed"; then
  msg_error "InvenTree package is not installed"
  exit 1
fi
INVENTREE_VERSION="$(dpkg-query -W -f='${Version}' inventree 2>/dev/null || echo "unknown")"
msg_ok "Installed ${APPLICATION:-InvenTree} (${INVENTREE_VERSION})"

msg_info "Verifying InvenTree services"
sleep 3
if systemctl is-active --quiet inventree-web && systemctl is-active --quiet nginx; then
  msg_ok "InvenTree web server and nginx are running"
else
  msg_warn "InvenTree services did not start cleanly — check: journalctl -u inventree-web / -u nginx"
fi

cat >/etc/inventree/credentials.txt <<EOF
InvenTree admin account
  Web UI: ${site_url} (nginx on port 80, proxying to localhost:6000)
  Username: ${admin_user}
  Email: ${admin_email}
  Password: ${admin_password}

Config: /etc/inventree/config.yaml (or: inventree config)
Data: /opt/inventree/data (default SQLite database: /opt/inventree/data/database.sqlite3)
Persistent files: /etc/inventree (credentials, keys, plugins list)

Control services: systemctl restart inventree / inventree-web / inventree-worker
Logs: inventree logs | Invoke tasks: inventree run invoke <command>
EOF
chmod 600 /etc/inventree/credentials.txt

echo "${INVENTREE_VERSION}" >/etc/inventree/inventree_version.txt
msg_ok "Installed ${APPLICATION:-InvenTree}"

echo -e "${INFO}${YW} Web UI:${CL} ${site_url} (nginx on port 80)"
echo -e "${INFO}${YW} Admin username:${CL} ${admin_user}"
echo -e "${INFO}${YW} Admin password (shown once):${CL} ${admin_password}"
echo -e "${INFO}${YW} Credentials saved to:${CL} /etc/inventree/credentials.txt"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/inventree.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc