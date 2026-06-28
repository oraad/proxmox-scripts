#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://www.music-assistant.io/ | Github: https://github.com/music-assistant/server

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/musicassistant"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Docker"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add docker docker-cli-compose
  $STD rc-service docker start
  $STD rc-update add docker default
else
  DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
  mkdir -p "$(dirname "$DOCKER_CONFIG_PATH")"
  echo -e '{\n  "log-driver": "journald"\n}' >"$DOCKER_CONFIG_PATH"
  setup_docker
fi
msg_ok "Installed Docker"

msg_info "Setting up ${APPLICATION:-Music Assistant}"
mkdir -p "${INSTALL_DIR}/data"

read -r -p "${TAB3}Mount a local music library into the container? (path or leave empty): " media_path
if [[ -n "${media_path}" && -d "${media_path}" ]]; then
  msg_ok "Will mount ${media_path} at /media"
elif [[ -n "${media_path}" ]]; then
  msg_warn "Path not found: ${media_path} — skipping media mount"
  media_path=""
fi

{
  cat <<'EOF'
services:
  music-assistant-server:
    image: ghcr.io/music-assistant/server:latest
    container_name: music-assistant-server
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./data:/data
EOF
  if [[ -n "${media_path}" ]]; then
    echo "      - ${media_path}:/media"
  fi
  cat <<'EOF'
    cap_add:
      - SYS_ADMIN
      - DAC_READ_SEARCH
    security_opt:
      - apparmor:unconfined
    environment:
      - LOG_LEVEL=info
EOF
} >"${INSTALL_DIR}/compose.yaml"

cd "${INSTALL_DIR}"
$STD docker compose pull
$STD docker compose up -d

docker inspect ghcr.io/music-assistant/server:latest --format='{{index .RepoDigests 0}}' 2>/dev/null \
  | awk -F@ '{print $2}' > "${INSTALL_DIR}/musicassistant_version.txt" || echo "latest" > "${INSTALL_DIR}/musicassistant_version.txt"
msg_ok "Installed ${APPLICATION:-Music Assistant}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/musicassistant.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc
