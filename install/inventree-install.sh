#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://inventree.org/ | Github: https://github.com/inventree/InvenTree

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/inventree"
STACK_URL="https://raw.githubusercontent.com/inventree/InvenTree/master/contrib/container"

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
  $STD apk add --no-cache curl ca-certificates openssl
else
  $STD apt-get install -y curl ca-certificates openssl
fi
msg_ok "Installed dependencies"

msg_info "Installing Docker"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache docker docker-cli-compose
  $STD rc-update add docker default
  $STD rc-service docker start
  for _ in $(seq 1 30); do
    [[ -S /var/run/docker.sock ]] && break
    sleep 1
  done
  if [[ ! -S /var/run/docker.sock ]]; then
    msg_error "Docker daemon did not start — check nesting/keyctl on the LXC"
    exit 1
  fi
else
  DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
  mkdir -p "$(dirname "$DOCKER_CONFIG_PATH")"
  echo -e '{\n  "log-driver": "journald"\n}' >"$DOCKER_CONFIG_PATH"
  setup_docker
fi
msg_ok "Installed Docker"

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

function inventree_wait_docker_health() {
  local name="$1" max="${2:-120}" i status
  for ((i = 0; i < max; i++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

# Generate credentials before the stack starts.
db_user="inventree"
db_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
admin_user="${var_admin_user:-admin}"
admin_email="${var_admin_email:-admin@inventree.local}"
admin_password="${var_admin_password:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

CT_IP="$(inventree_primary_ipv4)"
site_url="${var_site_url:-http://${CT_IP}}"

mkdir -p "${INSTALL_DIR}/data"

msg_info "Downloading InvenTree docker-compose files"
cd "${INSTALL_DIR}" || exit 1
$STD curl -fsSL -o docker-compose.yml "${STACK_URL}/docker-compose.yml"
$STD curl -fsSL -o .env "${STACK_URL}/.env"
$STD curl -fsSL -o Caddyfile "${STACK_URL}/Caddyfile"
if [[ ! -s docker-compose.yml || ! -s .env || ! -s Caddyfile ]]; then
  msg_error "Failed to download the InvenTree stack files"
  exit 1
fi
msg_ok "Downloaded InvenTree docker-compose files"

msg_info "Configuring ${APPLICATION:-InvenTree} environment"
sed -i "s|^INVENTREE_SITE_URL=.*|INVENTREE_SITE_URL=\"${site_url}\"|" "${INSTALL_DIR}/.env"
sed -i "s|^INVENTREE_EXT_VOLUME=.*|INVENTREE_EXT_VOLUME=${INSTALL_DIR}/data|" "${INSTALL_DIR}/.env"
sed -i "s|^INVENTREE_DB_USER=.*|INVENTREE_DB_USER=${db_user}|" "${INSTALL_DIR}/.env"
sed -i "s|^INVENTREE_DB_PASSWORD=.*|INVENTREE_DB_PASSWORD=${db_password}|" "${INSTALL_DIR}/.env"
if ! grep -q '^INVENTREE_SITE_URL=.*' "${INSTALL_DIR}/.env" ||
  ! grep -q "^INVENTREE_EXT_VOLUME=${INSTALL_DIR}/data$" "${INSTALL_DIR}/.env" ||
  ! grep -q "^INVENTREE_DB_USER=${db_user}$" "${INSTALL_DIR}/.env" ||
  ! grep -q "^INVENTREE_DB_PASSWORD=${db_password}$" "${INSTALL_DIR}/.env"; then
  msg_error "Could not patch the required InvenTree environment variables"
  exit 1
fi

# Admin account details are read by `invoke superuser` at first boot.
printf '\n# InvenTree superuser account (used once by invoke superuser)\nINVENTREE_ADMIN_USER=%s\nINVENTREE_ADMIN_PASSWORD=%s\nINVENTREE_ADMIN_EMAIL=%s\n' \
  "$admin_user" "$admin_password" "$admin_email" >>"${INSTALL_DIR}/.env"
msg_ok "Configured ${APPLICATION:-InvenTree} environment"

msg_info "Starting database and cache"
$STD docker compose up -d inventree-db inventree-cache
if ! inventree_wait_docker_health inventree-db 120; then
  msg_error "InvenTree database did not become healthy"
  exit 1
fi
msg_ok "Database and cache started"

msg_info "Running initial database setup (image pull + migrations, this may take a few minutes)"
if ! $STD docker compose run --rm -T inventree-server invoke update; then
  msg_error "Initial InvenTree database setup failed"
  exit 1
fi
msg_ok "Initial database setup complete"

msg_info "Creating administrator account"
if ! $STD docker compose run --rm -T inventree-server invoke superuser; then
  msg_error "Failed to create the administrator account"
  exit 1
fi

# Scrub admin credentials from the env file (upstream security recommendation).
sed -i '/^INVENTREE_ADMIN_/d' "${INSTALL_DIR}/.env"
cat >"${INSTALL_DIR}/credentials.txt" <<EOF
InvenTree admin account
  Web UI: ${site_url}
  Username: ${admin_user}
  Email: ${admin_email}
  Password: ${admin_password}

PostgreSQL database (in .env, do not change unless you know what you are doing)
  Database: inventree
  Username: ${db_user}
  Password: ${db_password}

Persistent data: ${INSTALL_DIR}/data (INVENTREE_EXT_VOLUME)
EOF
chmod 600 "${INSTALL_DIR}/credentials.txt"
msg_ok "Created administrator account"

msg_info "Starting ${APPLICATION:-InvenTree} stack"
$STD docker compose up -d
if ! inventree_wait_docker_health inventree-proxy 240; then
  msg_warn "The web server did not report healthy within 8 minutes — check: docker compose logs"
fi
msg_ok "Started ${APPLICATION:-InvenTree} stack"

img="$(docker inspect inventree-server --format='{{.Config.Image}}' 2>/dev/null || true)"
inv_image=""
[[ -n "$img" ]] && inv_image="$(docker image inspect "$img" --format='{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')"
echo "${inv_image:-latest}" >"${INSTALL_DIR}/inventree_version.txt"
msg_ok "Installed ${APPLICATION:-InvenTree}"

echo -e "${INFO}${YW} Web UI:${CL} ${site_url} (Caddy on port ${INVENTREE_HTTP_PORT:-80})"
echo -e "${INFO}${YW} Admin username:${CL} ${admin_user}"
echo -e "${INFO}${YW} Admin password (shown once):${CL} ${admin_password}"
echo -e "${INFO}${YW} Credentials saved to:${CL} ${INSTALL_DIR}/credentials.txt"

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