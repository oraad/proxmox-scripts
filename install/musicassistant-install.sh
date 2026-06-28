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

mkdir -p "${INSTALL_DIR}/data"

stop_spinner
media_path="${var_media_path:-$(prompt_input "${TAB3}Mount a local music library into the container? (path or leave empty):" "" 60)}"
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
