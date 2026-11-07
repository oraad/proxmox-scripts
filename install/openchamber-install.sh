#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://openchamber.dev/ | Github: https://github.com/openchamber/openchamber

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
OPENCHAMBER_BIN="${OPENCHAMBER_BIN:-/usr/local/bin/openchamber}"
OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
# Baked into the systemd unit — a non-numeric override would break the service
if [[ ! "$OPENCHAMBER_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: OPENCHAMBER_PORT must be numeric (got: ${OPENCHAMBER_PORT})" >&2
  exit 1
fi
OPENCHAMBER_ENV_FILE="${OPENCHAMBER_ENV_FILE:-/etc/openchamber/openchamber.env}"
OPENCODE_BIN="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
OPENCHAMBER_USER_UNIT="${OPENCHAMBER_USER_UNIT:-/root/.config/systemd/user/openchamber.service}"
OPENCHAMBER_SYSTEM_UNIT="${OPENCHAMBER_SYSTEM_UNIT:-/etc/systemd/system/openchamber.service}"
OPENCHAMBER_UNIT_NAME="${OPENCHAMBER_UNIT_NAME:-openchamber.service}"
OPENCHAMBER_RUNTIME_DIR="${OPENCHAMBER_RUNTIME_DIR:-/run/user/0}"
# Node.js major, installed from the NodeSource APT repo. Empty means the latest
# LTS at install time (resolved from nodejs.org below); pin with NODE_VERSION=24.
NODE_VERSION="${NODE_VERSION:-}"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -f /etc/alpine-release ]]; then
  msg_error "OpenChamber requires Node.js (installed via the NodeSource APT repo) — use the default (Debian 13) template."
  exit 1
fi

msg_info "Installing dependencies"
$STD apt-get install -y curl ca-certificates openssl jq dbus-user-session
msg_ok "Installed dependencies"

if [[ -z "$NODE_VERSION" ]]; then
  # nodejs.org lists releases newest first; the first entry with an LTS
  # codename is the current LTS line. NodeSource then installs its latest
  # minor/patch, so this tracks e.g. 26.13.x rather than a stale 26.0.
  NODE_VERSION="$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json 2>/dev/null \
    | jq -r '[.[] | select(.lts != false)][0].version // empty' 2>/dev/null \
    | sed 's/^v//' | cut -d. -f1)"
  if [[ ! "$NODE_VERSION" =~ ^[0-9]+$ ]]; then
    NODE_VERSION=26
    msg_warn "Could not resolve the latest Node.js LTS — falling back to Node.js 26"
  fi
fi

NODE_MAJOR_TARGET="${NODE_VERSION%%.*}"
msg_info "Installing Node.js ${NODE_MAJOR_TARGET} (latest minor/patch)"
NODE_VERSION="$NODE_VERSION" setup_nodejs
if ! command -v node >/dev/null 2>&1; then
  msg_error "Node.js binary not found after setup_nodejs"
  exit 1
fi
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if [[ ! "$NODE_MAJOR" =~ ^[0-9]+$ || "$NODE_MAJOR" -lt "$NODE_MAJOR_TARGET" ]]; then
  msg_error "Expected Node.js ${NODE_MAJOR_TARGET}.x — found: $(node -v 2>/dev/null || echo none)"
  exit 1
fi
# The package declares >= 24.14.0, so a pinned 24 major must not be an old 24.0.
if ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 24 || (a === 24 && b >= 14) ? 0 : 1)' >/dev/null 2>&1; then
  msg_error "OpenChamber requires Node.js >= 24.14.0 — found: $(node -v 2>/dev/null || echo none)"
  exit 1
fi
msg_ok "Installed Node.js $(node -v) (latest minor/patch)"

# Add the opencode binary dir to PATH for logins (installer ran with
# --no-modify-path so it does not touch per-user shell configs).
cat >/etc/profile.d/opencode.sh <<EOF
export PATH="$(dirname "${OPENCODE_BIN}"):\$PATH"
EOF

stop_spinner
msg_info "Installing OpenCode CLI (v2)"
# v1 and v2 have separate installers; openchamber targets OpenCode 2
$STD bash -c 'curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path'
if [[ ! -x "$OPENCODE_BIN" ]]; then
  msg_error "OpenCode binary not found at ${OPENCODE_BIN}"
  exit 1
fi
ln -sf "$OPENCODE_BIN" /usr/local/bin/opencode
OPENCODE_VERSION="$(/usr/local/bin/opencode --version 2>/dev/null || echo "unknown")"
msg_ok "Installed OpenCode CLI (${OPENCODE_VERSION})"

msg_info "Installing ${APPLICATION:-OpenChamber}"
$STD npm install -g @openchamber/web@latest
# npm's global prefix is not always /usr/local (NodeSource uses /usr), so
# resolve where npm actually put the bin and link it to the path the unit uses.
if [[ ! -x "$OPENCHAMBER_BIN" ]]; then
  _oc_resolved="$(command -v openchamber 2>/dev/null || true)"
  if [[ -z "$_oc_resolved" ]]; then
    _oc_prefix="$(npm prefix -g 2>/dev/null || true)"
    [[ -n "$_oc_prefix" && -x "${_oc_prefix}/bin/openchamber" ]] && _oc_resolved="${_oc_prefix}/bin/openchamber"
  fi
  if [[ -n "$_oc_resolved" && -x "$_oc_resolved" ]]; then
    ln -sf "$_oc_resolved" "$OPENCHAMBER_BIN"
  fi
  unset _oc_resolved _oc_prefix
fi
if [[ ! -x "$OPENCHAMBER_BIN" ]]; then
  msg_error "OpenChamber binary not found after npm install (npm prefix: $(npm prefix -g 2>/dev/null || echo unknown))"
  exit 1
fi
OPENCHAMBER_VERSION="$(npm list -g @openchamber/web --depth=0 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
msg_ok "Installed ${APPLICATION:-OpenChamber} (${OPENCHAMBER_VERSION:-unknown})"

msg_info "Configuring ${APPLICATION:-OpenChamber}"
# Password lives only in the env file (mode 0600) — never on the command line,
# where it would be visible in `ps`.
OPENCHAMBER_UI_PASSWORD="${var_ui_password:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"
install -d -m 0755 "$(dirname "$OPENCHAMBER_ENV_FILE")"
install -m 0600 /dev/null "$OPENCHAMBER_ENV_FILE"
cat >"$OPENCHAMBER_ENV_FILE" <<EOF
HOME=/root
OPENCHAMBER_HOST=0.0.0.0
OPENCHAMBER_UI_PASSWORD=${OPENCHAMBER_UI_PASSWORD}
EOF
chmod 600 "$OPENCHAMBER_ENV_FILE"
msg_ok "Configured ${APPLICATION:-OpenChamber}"

msg_info "Setting up ${APPLICATION:-OpenChamber} service"
# OpenChamber's updater only supports a systemd user service: it queues the
# install with `systemd-run --user` and restarts with `systemctl --user`. A
# system unit has no XDG_RUNTIME_DIR or session bus, so its Update button fails
# with "Failed to connect to user scope bus". Run it as root's user service and
# enable lingering so it still starts at boot with no login.
openchamber_write_user_unit() {
  install -d -m 0755 "$(dirname "$OPENCHAMBER_USER_UNIT")"
  cat >"$OPENCHAMBER_USER_UNIT" <<EOF
[Unit]
Description=OpenChamber web UI (OpenCode)

[Service]
Type=simple
EnvironmentFile=${OPENCHAMBER_ENV_FILE}
Environment=HOME=/root
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/root/.opencode/bin
ExecStart=${OPENCHAMBER_BIN} serve --port ${OPENCHAMBER_PORT} --host 0.0.0.0 --foreground
Restart=always
RestartSec=5
WorkingDirectory=/root
UMask=0022

[Install]
WantedBy=default.target
EOF
}

openchamber_switch_to_user_service() {
  local had_system_unit=0 healthy=0

  openchamber_write_user_unit

  $STD apt-get install -y dbus-user-session || {
    msg_error "Could not install dbus-user-session (needed for in-app updates)"
    return 1
  }
  loginctl enable-linger root || {
    msg_error "Could not enable lingering for root (the user service would stop at logout)"
    return 1
  }
  export XDG_RUNTIME_DIR="$OPENCHAMBER_RUNTIME_DIR"
  for _ in $(seq 1 30); do
    [[ -S "${XDG_RUNTIME_DIR}/systemd/private" ]] && break
    sleep 1
  done
  if [[ ! -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
    msg_error "Root's systemd user manager did not start (lingering is enabled)"
    return 1
  fi
  systemctl --user daemon-reload
  # dbus-user-session may have been installed after user@0 started, so its
  # socket is not pulled in by the already-active sockets.target.
  systemctl --user start dbus.socket 2>/dev/null || true
  for _ in $(seq 1 15); do
    [[ -S "${XDG_RUNTIME_DIR}/bus" ]] && break
    sleep 1
  done
  if [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    msg_warn "No user D-Bus socket at ${XDG_RUNTIME_DIR}/bus — the in-app Update button will fail"
  fi

  systemctl --user enable "$OPENCHAMBER_UNIT_NAME" || {
    msg_error "Could not enable ${OPENCHAMBER_UNIT_NAME} in root's user manager"
    return 1
  }

  if [[ -f "$OPENCHAMBER_SYSTEM_UNIT" ]]; then
    had_system_unit=1
    msg_info "Moving ${APPLICATION:-OpenChamber} from the system service to root's user service"
    systemctl disable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      systemctl is-active --quiet "$OPENCHAMBER_UNIT_NAME" || break
      sleep 1
    done
  fi

  systemctl --user restart "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 2
  done

  if [[ "$healthy" == "1" ]]; then
    if [[ "$had_system_unit" == "1" ]]; then
      rm -f "$OPENCHAMBER_SYSTEM_UNIT"
      systemctl daemon-reload
    fi
    return 0
  fi

  msg_error "${APPLICATION:-OpenChamber} did not become healthy as a user service"
  msg_error "Check: XDG_RUNTIME_DIR=${OPENCHAMBER_RUNTIME_DIR} journalctl --user -u ${OPENCHAMBER_UNIT_NAME}"
  systemctl --user --no-pager --full status "$OPENCHAMBER_UNIT_NAME" 2>&1 | head -n 20 || true
  if [[ "$had_system_unit" == "1" ]]; then
    msg_warn "Rolling back to the system service"
    systemctl --user disable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    systemctl enable --now "$OPENCHAMBER_UNIT_NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
  return 1
}

openchamber_switch_to_user_service || exit 1
msg_ok "Set up ${APPLICATION:-OpenChamber} service"

container_ip="${LOCAL_IP:-${IP:-}}"
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
fi
if [[ ! "$container_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$container_ip" == "127.0.0.1" ]]; then
  container_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
[[ -n "$container_ip" ]] || container_ip="127.0.0.1"

echo -e "${INFO}${YW} Web UI:${CL} http://${container_ip}:${OPENCHAMBER_PORT}"
echo -e "${INFO}${YW} Generated UI password (shown once):${CL} ${OPENCHAMBER_UI_PASSWORD}"
echo -e "${INFO}${YW} Saved to:${CL} ${OPENCHAMBER_ENV_FILE} (mode 0600)"

motd_ssh
customize

cat <<EOF >/usr/bin/update
#!/usr/bin/env bash
# Update entrypoint (generated) — resolves this app's ct script from its source repo.
export SCRIPT_SLUG="openchamber"
export UPDATE_SCRIPT_NAME="openchamber"
export COMMUNITY_SCRIPTS_URL="${REPO_RAW}"
set -a
[ -f /etc/profile.d/90-http-proxy.sh ] && . /etc/profile.d/90-http-proxy.sh
set +a
bash -c "\$(curl -fsSL "\${COMMUNITY_SCRIPTS_URL}/ct/openchamber.sh")"
EOF
chmod +x /usr/bin/update

cleanup_lxc
