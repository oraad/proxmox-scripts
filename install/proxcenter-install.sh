#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.proxcenter.io/ | Github: https://github.com/adminsyspro/proxcenter-ui

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
INSTALL_DIR="/opt/proxcenter"
COMPOSE_COMMUNITY_URL="https://raw.githubusercontent.com/adminsyspro/proxcenter-ui/main/docker-compose.community.yml"
COMPOSE_ENTERPRISE_URL="https://raw.githubusercontent.com/adminsyspro/proxcenter-ui/main/docker-compose.enterprise.yml"
VALIDATE_URL="https://proxcenter.io/api/v1/install/validate"
FRONTEND_IMAGE_REPO="ghcr.io/adminsyspro/proxcenter-frontend"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
if [[ -f /etc/alpine-release ]]; then
  $STD apk add --no-cache bash ca-certificates curl openssl tar jq newt
else
  $STD apt-get install -y curl openssl ca-certificates tar jq whiptail
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

proxcenter_primary_ipv4() {
  local ip="${IP:-}"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [[ -n "$ip" && "$ip" != "127.0.0.1" ]] || ip="127.0.0.1"
  printf '%s\n' "$ip"
}

env_existing() {
  local key="$1"
  local file="${INSTALL_DIR}/.env"
  [[ -f "$file" ]] || return 0
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

json_get() {
  local json="$1" key="$2"
  printf '%s' "$json" | jq -r --arg k "$key" 'if .[$k] == null then empty else (.[$k] | tostring) end'
}

edition="${var_edition:-community}"
edition="${edition,,}"
image_version="${var_image_version:-latest}"
install_token="${var_install_token:-}"
license_key="${var_license_key:-}"
frontend_image="${FRONTEND_IMAGE_REPO}:${image_version}"

case "$edition" in
community | enterprise) ;;
*)
  msg_error "var_edition must be community or enterprise"
  exit 1
  ;;
esac

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" || exit 1

if [[ "$edition" == "enterprise" ]]; then
  if [[ -z "$install_token" ]]; then
    msg_error "Enterprise install requires var_install_token"
    exit 1
  fi

  msg_info "Validating Enterprise install token"
  hostname_val="$(hostname 2>/dev/null || echo unknown)"
  os_val="unknown"
  if [[ -f /etc/os-release ]]; then
    os_val="$(awk -F= '
      /^ID=/ { gsub(/"/, "", $2); id=$2 }
      /^VERSION_ID=/ { gsub(/"/, "", $2); ver=$2 }
      END { print id " " ver }
    ' /etc/os-release)"
    os_val="${os_val% }"
  fi
  payload="$(jq -n --arg token "$install_token" --arg hostname "$hostname_val" --arg os "$os_val" \
    '{token:$token,hostname:$hostname,os:$os}')"
  response="$(curl -sS -w "\n%{http_code}" -X POST "$VALIDATE_URL" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  http_code="$(printf '%s' "$response" | tail -n1)"
  body="$(printf '%s' "$response" | sed '$d')"
  if [[ "$http_code" != "200" ]]; then
    err_msg="$(json_get "$body" "message")"
    msg_error "Token validation failed${err_msg:+: ${err_msg}} (HTTP ${http_code})"
    exit 1
  fi
  valid="$(json_get "$body" "valid")"
  valid="${valid,,}"
  if [[ "$valid" != "true" && "$valid" != "1" ]]; then
    err_msg="$(json_get "$body" "message")"
    msg_error "Invalid Enterprise token${err_msg:+: ${err_msg}}"
    exit 1
  fi
  registry="$(json_get "$body" "registry")"
  registry_user="$(json_get "$body" "username")"
  registry_pass="$(json_get "$body" "password")"
  if [[ -z "$registry" || -z "$registry_user" || -z "$registry_pass" ]]; then
    msg_error "Failed to retrieve registry credentials from the ProxCenter API"
    exit 1
  fi
  msg_ok "Enterprise token validated"

  msg_info "Authenticating to container registry"
  if ! echo "$registry_pass" | docker login "$registry" -u "$registry_user" --password-stdin >/dev/null 2>&1; then
    msg_error "Failed to authenticate to ${registry}"
    exit 1
  fi
  msg_ok "Authenticated to ${registry}"
fi

msg_info "Configuring ProxCenter (${edition})"
if [[ "$edition" == "enterprise" ]]; then
  mkdir -p "${INSTALL_DIR}/config"
  if ! curl -fsSL "$COMPOSE_ENTERPRISE_URL" -o docker-compose.yml; then
    msg_error "Failed to download Enterprise compose file"
    exit 1
  fi
  sed -i '/^volumes:/,$d' docker-compose.yml
  cat >>docker-compose.yml <<'EOF'
volumes:
  proxcenter_data:
    external: true
  orchestrator_data:
    external: true
  postgres_data:
    external: true
EOF
else
  if ! curl -fsSL "$COMPOSE_COMMUNITY_URL" -o docker-compose.yml; then
    msg_error "Failed to download Community compose file"
    exit 1
  fi
  sed -i '/^volumes:/,$d' docker-compose.yml
  cat >>docker-compose.yml <<'EOF'
volumes:
  proxcenter_data:
    external: true
  postgres_data:
    external: true
EOF
fi

container_ip="$(proxcenter_primary_ipv4)"
nextauth_url="${var_nextauth_url:-http://${container_ip}:3000}"
app_secret="$(env_existing APP_SECRET)"
[[ -n "$app_secret" ]] || app_secret="$(openssl rand -hex 32)"
nextauth_secret="$(env_existing NEXTAUTH_SECRET)"
[[ -n "$nextauth_secret" ]] || nextauth_secret="$(openssl rand -hex 32)"
postgres_password="$(env_existing POSTGRES_PASSWORD)"
[[ -n "$postgres_password" ]] || postgres_password="$(openssl rand -hex 24)"
tz="$(cat /etc/timezone 2>/dev/null || echo UTC)"

if [[ "$edition" == "enterprise" ]]; then
  orchestrator_api_key="$(env_existing ORCHESTRATOR_API_KEY)"
  if [[ -z "$orchestrator_api_key" || "$orchestrator_api_key" == "your-orchestrator-api-key-change-me" ]]; then
    orchestrator_api_key="$(openssl rand -hex 32)"
  fi
  [[ -n "$license_key" ]] || license_key="$(env_existing LICENSE_KEY)"
  cat >"${INSTALL_DIR}/.env" <<EOF
# ProxCenter Enterprise Edition
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)

VERSION=${image_version}
APP_SECRET=${app_secret}
NEXTAUTH_SECRET=${nextauth_secret}
NEXTAUTH_URL=${nextauth_url}
APP_URL=${nextauth_url}
TZ=${tz}
LICENSE_KEY=${license_key}
ORCHESTRATOR_URL=http://orchestrator:8080
ORCHESTRATOR_API_KEY=${orchestrator_api_key}
POSTGRES_PASSWORD=${postgres_password}
EOF
  cat >"${INSTALL_DIR}/config/orchestrator.yaml" <<EOF
api:
  address: ":8080"
  read_timeout: 30s
  write_timeout: 30s

database:
  driver: postgres
  dsn: "postgres://proxcenter:${postgres_password}@postgres:5432/proxcenter?sslmode=disable"

proxmox:
  app_secret: "${app_secret}"
  shared_data_path: /app/shared_data

license:
  key: "${license_key}"

logging:
  level: info
  format: json
EOF
  chmod 644 "${INSTALL_DIR}/config/orchestrator.yaml"
else
  cat >"${INSTALL_DIR}/.env" <<EOF
# ProxCenter Community Edition
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)

APP_SECRET=${app_secret}
NEXTAUTH_SECRET=${nextauth_secret}
NEXTAUTH_URL=${nextauth_url}
APP_URL=${nextauth_url}
VERSION=${image_version}
TZ=${tz}
POSTGRES_PASSWORD=${postgres_password}
EOF
fi
chmod 600 "${INSTALL_DIR}/.env"
printf '%s\n' "$edition" >"${INSTALL_DIR}/edition"
msg_ok "Wrote compose configuration"

msg_info "Pulling ProxCenter images"
$STD docker compose pull
msg_ok "Images pulled"

msg_info "Creating Docker volumes"
docker volume create proxcenter_data >/dev/null 2>&1 || true
docker volume create postgres_data >/dev/null 2>&1 || true
if [[ "$edition" == "enterprise" ]]; then
  docker volume create orchestrator_data >/dev/null 2>&1 || true
fi
$STD docker run --rm --user root --entrypoint "" \
  -v proxcenter_data:/app/data \
  "$frontend_image" \
  sh -c "mkdir -p /app/data && chown -R 1001:1001 /app/data" || true
msg_ok "Volumes initialized"

msg_info "Starting ProxCenter"
$STD docker compose up -d
msg_ok "Containers started"

msg_info "Waiting for ProxCenter to become healthy"
healthy=0
for _ in $(seq 1 60); do
  if curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [[ "$healthy" -ne 1 ]]; then
  msg_error "Frontend failed to start within 2 minutes — check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
  exit 1
fi

if [[ "$edition" == "enterprise" ]]; then
  orch_healthy=0
  for _ in $(seq 1 60); do
    orch_status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' proxcenter-orchestrator 2>/dev/null || echo missing)"
    if [[ "$orch_status" == "healthy" ]]; then
      orch_healthy=1
      break
    fi
    sleep 2
  done
  if [[ "$orch_healthy" -ne 1 ]]; then
    msg_error "Orchestrator failed to start within 2 minutes — check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs orchestrator"
    exit 1
  fi
fi
msg_ok "ProxCenter is healthy"

docker inspect "$frontend_image" --format='{{index .RepoDigests 0}}' 2>/dev/null \
  | awk -F@ '{print $2}' >"${INSTALL_DIR}/proxcenter_version.txt" || echo "$image_version" >"${INSTALL_DIR}/proxcenter_version.txt"

msg_ok "Installed ${APPLICATION:-ProxCenter}"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${REPO_RAW}/ct/proxcenter.sh)"
EOF
chmod +x /usr/bin/update

cleanup_lxc
