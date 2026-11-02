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
# Current Node.js LTS (26 "Lithium"). Override with NODE_VERSION=24 to pin the
# package's declared minimum instead (the engine's setup_nodejs default is 24).
NODE_VERSION="${NODE_VERSION:-26}"

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
$STD apt-get install -y curl ca-certificates openssl jq
msg_ok "Installed dependencies"

NODE_MAJOR_TARGET="${NODE_VERSION%%.*}"
msg_info "Installing Node.js ${NODE_VERSION}"
NODE_VERSION="$NODE_VERSION" setup_nodejs
if ! command -v node >/dev/null 2>&1; then
  msg_error "Node.js binary not found after setup_nodejs"
  exit 1
fi
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if [[ ! "$NODE_MAJOR" =~ ^[0-9]+$ || "$NODE_MAJOR" -lt "$NODE_MAJOR_TARGET" ]]; then
  msg_error "Expected Node.js ${NODE_VERSION} (OpenChamber needs >= 24.14.0) — found: $(node -v 2>/dev/null || echo none)"
  exit 1
fi
msg_ok "Installed Node.js ${NODE_VERSION} ($(node -v))"

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
cat >/etc/systemd/system/openchamber.service <<EOF
[Unit]
Description=OpenChamber web UI (OpenCode)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${OPENCHAMBER_ENV_FILE}
Environment=HOME=/root
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/root/.opencode/bin
ExecStart=${OPENCHAMBER_BIN} serve --port ${OPENCHAMBER_PORT} --host 0.0.0.0 --foreground
Restart=always
RestartSec=5
WorkingDirectory=/root
UMask=0022

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable --now openchamber
msg_ok "Set up ${APPLICATION:-OpenChamber} service"

msg_info "Waiting for ${APPLICATION:-OpenChamber} to become healthy"
healthy=0
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${OPENCHAMBER_PORT}/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [[ "$healthy" != "1" ]]; then
  msg_error "OpenChamber service failed to start — check: journalctl -u openchamber"
  exit 1
fi
msg_ok "${APPLICATION:-OpenChamber} is healthy"

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
