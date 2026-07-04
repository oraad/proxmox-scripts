#!/usr/bin/env bash
# Shared constants and helpers for Solar AI Optimizer Proxmox scripts.

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
SOLAR_APP_RAW="${SOLAR_APP_RAW:-https://raw.githubusercontent.com/oraad/solar-ai-optimizer/main}"
SOLAR_IMAGE="${SOLAR_IMAGE:-ghcr.io/oraad/solar-ai-optimizer}"
SOLAR_IMAGE_TAG="${SOLAR_IMAGE_TAG:-latest}"
SOLAR_CONTAINER="${SOLAR_CONTAINER:-solar-optimizer}"
SOLAR_DATA_VOLUME="${SOLAR_DATA_VOLUME:-solar-data}"
SOLAR_DATA_PATH="${SOLAR_DATA_PATH:-/app/data}"
SOLAR_PORT="${SOLAR_PORT:-8000}"
SOLAR_HEALTH_PATH="${SOLAR_HEALTH_PATH:-/api/health}"
SOLAR_INSTALL_DIR="${SOLAR_INSTALL_DIR:-/opt/solar-ai-optimizer}"
SOLAR_VERSION_FILE="${SOLAR_VERSION_FILE:-/opt/solar-ai-optimizer_version.txt}"
SOLAR_ENV_FILE="${SOLAR_INSTALL_DIR}/solar.env"
SOLAR_ADMIN_CREDS_FILE="${SOLAR_INSTALL_DIR}/.install-admin-credentials"

solar_image_ref() {
  echo "${SOLAR_IMAGE}:${SOLAR_IMAGE_TAG}"
}

solar_default_env() {
  cat <<'EOF'
SHADOW_MODE=true
LOG_LEVEL=INFO
DATA_DIR=/app/data
DATABASE_URL=sqlite+aiosqlite:////app/data/solar.db
TRUST_INGRESS_HEADERS=true
EOF
}

solar_random_password() {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24
}

solar_random_session_secret() {
  openssl rand -hex 32
}

solar_bcrypt_hash() {
  local password="$1"
  docker run --rm -e "PW=${password}" --entrypoint python "$(solar_image_ref)" -c \
    'import bcrypt, os; print(bcrypt.hashpw(os.environ["PW"].encode(), bcrypt.gensalt()).decode())'
}

solar_generate_admin_credentials() {
  SOLAR_ADMIN_USER="${SOLAR_ADMIN_USER:-admin}"
  SOLAR_ADMIN_PASSWORD="$(solar_random_password)"
  SOLAR_ADMIN_PASSWORD_HASH="$(solar_bcrypt_hash "$SOLAR_ADMIN_PASSWORD")"
  SOLAR_ADMIN_SESSION_SECRET="$(solar_random_session_secret)"
}

solar_env_get() {
  local key="$1"
  [[ -f "$SOLAR_ENV_FILE" ]] || return 1
  grep -E "^${key}=" "$SOLAR_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

solar_env_set() {
  local key="$1"
  local value="$2"
  local tmp line

  mkdir -p "$SOLAR_INSTALL_DIR"
  touch "$SOLAR_ENV_FILE"
  if grep -qE "^${key}=" "$SOLAR_ENV_FILE" 2>/dev/null; then
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "${key}="* ]]; then
        printf '%s=%s\n' "$key" "$value"
      else
        printf '%s\n' "$line"
      fi
    done <"$SOLAR_ENV_FILE" >"$tmp"
    mv "$tmp" "$SOLAR_ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$SOLAR_ENV_FILE"
  fi
}

solar_write_admin_credentials_file() {
  printf '%s\n%s\n' "$SOLAR_ADMIN_USER" "$SOLAR_ADMIN_PASSWORD" >"$SOLAR_ADMIN_CREDS_FILE"
  chmod 600 "$SOLAR_ADMIN_CREDS_FILE"
}

solar_ensure_env_auth() {
  local trust_val has_hash has_plain session

  SOLAR_ENV_PATCHED=0
  SOLAR_ADMIN_CREDENTIALS_GENERATED=0

  mkdir -p "$SOLAR_INSTALL_DIR"
  [[ -f "$SOLAR_ENV_FILE" ]] || touch "$SOLAR_ENV_FILE"

  trust_val="$(solar_env_get TRUST_INGRESS_HEADERS 2>/dev/null || true)"
  if [[ "$trust_val" != "true" ]]; then
    solar_env_set TRUST_INGRESS_HEADERS true
    SOLAR_ENV_PATCHED=1
  fi

  has_hash="$(solar_env_get LOCAL_ADMIN_PASSWORD_HASH 2>/dev/null || true)"
  has_plain="$(solar_env_get LOCAL_ADMIN_PASSWORD 2>/dev/null || true)"
  if [[ -z "$has_hash" && -z "$has_plain" ]]; then
    solar_generate_admin_credentials
    solar_env_set LOCAL_ADMIN_USERNAME "$SOLAR_ADMIN_USER"
    solar_env_set LOCAL_ADMIN_PASSWORD_HASH "$SOLAR_ADMIN_PASSWORD_HASH"
    solar_env_set SESSION_SECRET "$SOLAR_ADMIN_SESSION_SECRET"
    SOLAR_ADMIN_CREDENTIALS_GENERATED=1
    SOLAR_ENV_PATCHED=1
    solar_write_admin_credentials_file
  else
    session="$(solar_env_get SESSION_SECRET 2>/dev/null || true)"
    if [[ -z "$session" ]]; then
      solar_env_set SESSION_SECRET "$(solar_random_session_secret)"
      SOLAR_ENV_PATCHED=1
    fi
  fi
}

solar_show_admin_credentials() {
  [[ "${SOLAR_ADMIN_CREDENTIALS_GENERATED:-0}" == "1" ]] || return 0
  msg_ok "Local admin credentials (save these — not shown again):"
  echo -e "${INFO}${YW}Username:${CL} ${SOLAR_ADMIN_USER}"
  echo -e "${INFO}${YW}Password:${CL} ${SOLAR_ADMIN_PASSWORD}"
}

solar_install_reset_script() {
  local dest="${SOLAR_INSTALL_DIR}/reset-local-password.sh"
  local app_raw="${SOLAR_APP_RAW:-https://raw.githubusercontent.com/oraad/solar-ai-optimizer/main}"
  mkdir -p "$SOLAR_INSTALL_DIR"
  curl -fsSL "${app_raw}/scripts/reset-local-password.sh" -o "$dest"
  sed -i 's/\r$//' "$dest" 2>/dev/null || true
  chmod +x "$dest"
}

solar_reset_local_password() {
  local script="${SOLAR_INSTALL_DIR}/reset-local-password.sh"
  if [[ ! -x "$script" ]]; then
    solar_install_reset_script
  fi
  SOLAR_CONTAINER="${SOLAR_CONTAINER:-solar-optimizer}" bash "$script" "$@"
}

solar_write_update_command() {
  local repo_raw="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
  cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL ${repo_raw}/ct/solar-ai-optimizer.sh)"
EOF
  chmod +x /usr/bin/update
}

solar_install_docker() {
  local docker_config_path='/etc/docker/daemon.json'
  local i

  if [[ -f /etc/alpine-release ]]; then
    msg_info "Installing Docker Engine (Alpine)"
    $STD apk add --no-cache docker openssl
    if ! grep -q 'rc_cgroup_mode' /etc/rc.conf 2>/dev/null; then
      echo 'rc_cgroup_mode="unified"' >>/etc/rc.conf
    fi
    mkdir -p "$(dirname "$docker_config_path")"
    echo -e '{\n  "log-driver": "json-file"\n}' >"$docker_config_path"
    rc-update add docker default
    rc-service docker start
    for i in $(seq 1 30); do
      if docker info >/dev/null 2>&1; then
        msg_ok "Installed Docker Engine"
        return 0
      fi
      sleep 1
    done
    msg_error "Docker failed to start — check: rc-service docker status"
    return 1
  fi

  msg_info "Installing Docker Engine"
  mkdir -p "$(dirname "$docker_config_path")"
  echo -e '{\n  "log-driver": "journald"\n}' >"$docker_config_path"
  if declare -f setup_docker >/dev/null 2>&1; then
    setup_docker
  else
    $STD sh <(curl -fsSL https://get.docker.com)
  fi
  msg_ok "Installed Docker Engine"
}

solar_write_env_file() {
  mkdir -p "$SOLAR_INSTALL_DIR"
  solar_default_env >"$SOLAR_ENV_FILE"
  cat >>"$SOLAR_ENV_FILE" <<'EOF'

# Optional overrides (uncomment and set as needed):
# API_TOKEN=change-me
# HA_BASE_URL=http://homeassistant.local:8123
# HA_TOKEN=
# SOLCAST_API_KEY=
# SOLCAST_RESOURCE_ID=
# ML_LOAD_ENABLED=false
# LLM_ENABLED=false
EOF
  solar_ensure_env_auth
}

solar_source_common() {
  # shellcheck disable=SC1090
  source <(curl -fsSL "${REPO_RAW}/misc/solar-common.sh")
}

solar_latest_github_tag() {
  curl -fsSL "https://api.github.com/repos/oraad/solar-ai-optimizer/releases/latest" 2>/dev/null \
    | grep -Po '"tag_name":\s*"\K[^"]+' || echo "latest"
}

solar_installed_ref() {
  if [[ -f "$SOLAR_VERSION_FILE" ]]; then
    cat "$SOLAR_VERSION_FILE"
  fi
}

solar_current_image_ref() {
  docker image inspect --format='{{index .RepoDigests 0}}' "$(solar_image_ref)" 2>/dev/null \
    || docker image inspect --format='{{.Id}}' "$(solar_image_ref)" 2>/dev/null \
    || echo ""
}

solar_wait_healthy() {
  local host="${1:-127.0.0.1}"
  local port="${2:-$SOLAR_PORT}"
  local path="${3:-$SOLAR_HEALTH_PATH}"
  local timeout="${4:-120}"
  local elapsed=0

  while [[ "$elapsed" -lt "$timeout" ]]; do
    if curl -fsS "http://${host}:${port}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

solar_ensure_data_volume() {
  docker volume inspect "$SOLAR_DATA_VOLUME" >/dev/null 2>&1 \
    || docker volume create "$SOLAR_DATA_VOLUME" >/dev/null
}

solar_run_container() {
  solar_ensure_data_volume
  local -a run_args=(
    -d
    --name "$SOLAR_CONTAINER"
    --restart unless-stopped
    --env-file "$SOLAR_ENV_FILE"
    -v "${SOLAR_DATA_VOLUME}:${SOLAR_DATA_PATH}"
    -p "${SOLAR_PORT}:8000"
    -v /var/run/docker.sock:/var/run/docker.sock
    -e SELF_UPDATE_ENABLED=true
    -e "SELF_UPDATE_ENV_FILE=${SOLAR_ENV_FILE}"
    -e "SELF_UPDATE_IMAGE=$(solar_image_ref)"
  )
  docker run "${run_args[@]}" "$(solar_image_ref)"
}

solar_recreate_container() {
  docker stop "$SOLAR_CONTAINER" 2>/dev/null || true
  docker rm "$SOLAR_CONTAINER" 2>/dev/null || true
  solar_run_container
}

solar_image_repo_from_ref() {
  local ref="${1:-}"
  ref="${ref%%@*}"
  if [[ "$ref" == *:* ]]; then
    echo "${ref%:*}"
  else
    echo "$ref"
  fi
}

solar_cleanup_old_images() {
  local previous_image_id="${1:-}"
  local image_cleanup="${IMAGE_CLEANUP:-1}"
  local image_retention="${IMAGE_RETENTION:-2}"

  case "$image_cleanup" in
    0 | false | FALSE) return 0 ;;
  esac

  local repo current_id image_id
  repo="$(solar_image_repo_from_ref "$(solar_image_ref)")"
  [[ -z "$repo" ]] && return 0

  current_id="$(docker inspect -f '{{.Image}}' "$SOLAR_CONTAINER" 2>/dev/null || true)"

  if [[ -n "$previous_image_id" && "$previous_image_id" != "$current_id" ]]; then
    docker rmi "$previous_image_id" 2>/dev/null || true
  fi

  while IFS= read -r image_id; do
    [[ -z "$image_id" ]] && continue
    [[ "$image_id" == "$current_id" ]] && continue
    docker rmi "$image_id" 2>/dev/null || true
  done < <(docker images "$repo" --format '{{.ID}}' | tail -n +$((image_retention + 1)))

  docker image prune -f >/dev/null 2>&1 || true
}

solar_save_version() {
  local ref
  ref="$(solar_current_image_ref)"
  [[ -z "$ref" ]] && ref="$(solar_image_ref)"
  echo "$ref" >"$SOLAR_VERSION_FILE"
}

solar_is_installed() {
  [[ -d "$SOLAR_INSTALL_DIR" ]] && docker ps -a --format '{{.Names}}' | grep -qx "$SOLAR_CONTAINER"
}

solar_is_recoverable() {
  [[ -d "$SOLAR_INSTALL_DIR" && -f "$SOLAR_ENV_FILE" ]]
}

solar_recover_missing_container() {
  if solar_is_installed; then
    return 0
  fi
  if ! solar_is_recoverable; then
    return 1
  fi
  msg_warn "Container missing but install dir found — recreating from ${SOLAR_ENV_FILE}"
  solar_ensure_env_auth
  $STD docker pull "$(solar_image_ref)"
  solar_recreate_container
  solar_save_version
  return 0
}
