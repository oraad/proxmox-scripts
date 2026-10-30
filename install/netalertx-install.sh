#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://netalertx.com/ | Github: https://github.com/netalertx/NetAlertX

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/netalertx"

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

mkdir -p "${INSTALL_DIR}/data/config" "${INSTALL_DIR}/data/db"
chown -R 20211:20211 "${INSTALL_DIR}/data"

if [[ -n "${var_scan_subnets:-}" ]]; then
  msg_ok "Configured SCAN_SUBNETS: ${var_scan_subnets}"
fi

{
  cat <<'EOF'
services:
  netalertx:
    image: ghcr.io/netalertx/netalertx:latest
    container_name: netalertx
    network_mode: host
    restart: unless-stopped
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    tmpfs:
      - /tmp:uid=20211,gid=20211,mode=1700,rw,noexec,nosuid,nodev
    environment:
      PORT: "20211"
      GRAPHQL_PORT: "20212"
EOF
  if [[ -n "${var_scan_subnets:-}" ]]; then
    override_json=$(printf '{"SCAN_SUBNETS":"%s"}' "${var_scan_subnets}")
    override_yaml=${override_json//\\/\\\\}
    override_yaml=${override_yaml//\"/\\\"}
    echo "      APP_CONF_OVERRIDE: \"${override_yaml}\""
  fi
} >"${INSTALL_DIR}/compose.yaml"

cd "${INSTALL_DIR}" || exit 1
$STD docker compose pull
$STD docker compose up -d

msg_info "Waiting for NetAlertX to start"
running=0
for _ in $(seq 1 30); do
  if [[ "$(docker inspect --format='{{.State.Running}}' netalertx 2>/dev/null)" == "true" ]] && curl -sf http://127.0.0.1:20211 >/dev/null 2>&1; then
    running=1
    break
  fi
  sleep 2
done
if [[ "$running" -ne 1 ]]; then
  msg_error "NetAlertX failed to start — check: docker compose -f ${INSTALL_DIR}/compose.yaml logs"
  exit 1
fi
msg_ok "NetAlertX is running"

digest="$(docker inspect ghcr.io/netalertx/netalertx:latest --format='{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}')"
: "${digest:=latest}"
echo "$digest" >"${INSTALL_DIR}/netalertx_version.txt"
msg_ok "Installed ${APPLICATION:-NetAlertX}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
# Update entrypoint (generated) — resolves this app's ct script from its source repo.
export SCRIPT_SLUG="netalertx"
export UPDATE_SCRIPT_NAME="netalertx"
export COMMUNITY_SCRIPTS_URL="${REPO_RAW}"
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL "\${COMMUNITY_SCRIPTS_URL}/ct/netalertx.sh")"
EOF
chmod +x /usr/bin/update

cleanup_lxc
