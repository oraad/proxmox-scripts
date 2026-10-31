#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://github.com/wow-signal-dev/metadata-remote

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/metadata-remote"

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

media_path=""
if [[ -n "${var_media_path:-}" && -d /media ]]; then
  media_path="/media"
  msg_ok "Using bind-mounted library at /media"
elif [[ -n "${var_media_path:-}" ]]; then
  msg_warn "var_media_path was set but /media is missing in the container — skipping media mount"
fi

mkdir -p "${INSTALL_DIR}"
{
  cat <<'EOF'
services:
  metadata-remote:
    image: ghcr.io/wow-signal-dev/metadata-remote:latest
    container_name: metadata-remote
    network_mode: host
    restart: unless-stopped
    environment:
      PUID: "1000"
      PGID: "1000"
    volumes:
EOF
  if [[ -n "${media_path}" ]]; then
    echo "      - ${media_path}:/music"
  fi
} >"${INSTALL_DIR}/compose.yaml"

cd "${INSTALL_DIR}" || exit 1
$STD docker compose pull
$STD docker compose up -d

msg_info "Waiting for Metadata Remote to start"
running=0
for _ in $(seq 1 30); do
  if [[ "$(docker inspect --format='{{.State.Running}}' metadata-remote 2>/dev/null)" == "true" ]] && curl -sf http://127.0.0.1:8338 >/dev/null 2>&1; then
    running=1
    break
  fi
  sleep 2
done
if [[ "$running" -ne 1 ]]; then
  msg_error "Metadata Remote failed to start — check: docker compose -f ${INSTALL_DIR}/compose.yaml logs"
  exit 1
fi
msg_ok "Metadata Remote is running"

digest="$(docker inspect ghcr.io/wow-signal-dev/metadata-remote:latest --format='{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')"
: "${digest:=latest}"
echo "$digest" >"${INSTALL_DIR}/metadata_remote_version.txt"
msg_ok "Installed ${APPLICATION:-Metadata Remote}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
# Update entrypoint (generated) — resolves this app's ct script from its source repo.
export SCRIPT_SLUG="metadata-remote"
export UPDATE_SCRIPT_NAME="metadata-remote"
export COMMUNITY_SCRIPTS_URL="${REPO_RAW}"
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL "\${COMMUNITY_SCRIPTS_URL}/ct/metadata-remote.sh")"
EOF
chmod +x /usr/bin/update

cleanup_lxc