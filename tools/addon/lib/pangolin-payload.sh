#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
#
# Shared Pangolin addon payload. Source this file; do not execute it.
# It provides architecture detection, release metadata parsing, and sha256
# verification used by the addon entry point and its tests.

PANGOLIN_ROOT="${PANGOLIN_ROOT:-}"
p() { printf '%s%s' "$PANGOLIN_ROOT" "$1"; }

PANGOLIN_BIN="${PANGOLIN_BIN:-$(p /usr/local/bin/pangolin)}"
PANGOLIN_STATE_FILE="${PANGOLIN_STATE_FILE:-$(p /var/lib/pangolin/cli.json)}"
PANGOLIN_RELEASE_API="${PANGOLIN_RELEASE_API:-https://api.fossorial.io/api/v1/versions/cli}"
PANGOLIN_RELEASE_BASE="${PANGOLIN_RELEASE_BASE:-https://github.com/fosrl/cli/releases/download}"
PANGOLIN_SELINUX_ENFORCE="${PANGOLIN_SELINUX_ENFORCE:-/sys/fs/selinux/enforce}"

# Map a `uname -m` machine name to a release asset architecture.
arch_from_uname() {
  case "$1" in
  x86_64 | amd64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  armv7l | armv7*) echo arm32 ;;
  armv6l | armv6*) echo arm32v6 ;;
  riscv64) echo riscv64 ;;
  *) return 1 ;;
  esac
}

# Map a `dpkg --print-architecture` name to a release asset architecture.
arch_from_dpkg() {
  case "$1" in
  amd64) echo amd64 ;;
  arm64) echo arm64 ;;
  armhf | armel) echo arm32 ;;
  riscv64) echo riscv64 ;;
  *) return 1 ;;
  esac
}

# Detect the release asset architecture, preferring dpkg when available.
detect_arch() {
  local arch machine
  if command -v dpkg >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    if [[ -n "$arch" ]]; then
      arch_from_dpkg "$arch" && return 0
      echo "Unsupported architecture: $arch" >&2
      return 1
    fi
  fi
  machine="$(uname -m)"
  arch_from_uname "$machine" && return 0
  echo "Unsupported architecture: $machine" >&2
  return 1
}

# Print the latest CLI version from a Fossorial release API response.
release_version() {
  local version
  version="$(printf '%s' "$1" | sed -n 's/.*"latestVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

# Print the sha256 digest of one release asset from a Fossorial API response.
release_digest() {
  local json="$1" asset="$2" escaped digest
  escaped="$(printf '%s' "$asset" | sed 's/[][\.*^$/]/\\&/g')"
  digest="$(printf '%s' "$json" |
    sed -n "s/.*\"$escaped\"[[:space:]]*:[[:space:]]*\"\([0-9a-fA-F]\{64\}\)\".*/\1/p" | head -n 1)"
  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}

# Verify a file against an expected sha256 hex digest.
verify_sha256() {
  local path="$1" expected="$2" actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$path" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$path" | cut -d' ' -f1)"
  else
    echo "No sha256 tool found (sha256sum or shasum)" >&2
    return 1
  fi
  [[ "$actual" == "$expected" ]]
}

# Escape a value for use inside a JSON string.
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

# Print a static-credential site configuration as JSON.
site_config_static() {
  printf '{"endpoint":"%s","id":"%s","secret":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")"
}

# Print a provisioning-key site configuration as JSON.
site_config_provisioning() {
  printf '{"endpoint":"%s","provisioningKey":"%s","name":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")"
}

# Succeed when a site configuration holds credentials and no provisioning key.
site_config_has_credentials() {
  local path="$1"
  grep -q '"id"[[:space:]]*:' "$path" &&
    grep -q '"secret"[[:space:]]*:' "$path" &&
    ! grep -q '"provisioningKey"[[:space:]]*:' "$path"
}

# Write content to a private file, creating the parent directory if needed.
write_private_file() {
  local path="$1" content="$2"
  install -d -m 0755 "$(dirname "$path")"
  install -m 0600 /dev/null "$path"
  printf '%s\n' "$content" >"$path"
}

# Add an exact tag to a semicolon-separated list without duplicates.
add_tag() {
  local current="$1" tag="$2" entry out="" found=0
  local -a entries
  IFS=';' read -r -a entries <<<"$current" || true
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == "$tag" ]]; then
      found=1
    fi
    case ";$out;" in
    *";$entry;"*) ;;
    *) out="${out:+$out;}$entry" ;;
    esac
  done
  if [[ -n "$tag" && "$found" -eq 0 ]]; then
    out="${out:+$out;}$tag"
  fi
  printf '%s' "$out"
}

# Remove an exact tag from a semicolon-separated list.
remove_tag() {
  local current="$1" tag="$2" entry out=""
  local -a entries
  IFS=';' read -r -a entries <<<"$current" || true
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == "$tag" ]]; then
      continue
    fi
    out="${out:+$out;}$entry"
  done
  printf '%s' "$out"
}

# Append a line to a config file, adding a trailing newline first if needed.
_tun_append() {
  local conf="$1" line="$2"
  if [[ -s "$conf" && -n "$(tail -c 1 "$conf")" ]]; then
    printf '\n' >>"$conf"
  fi
  printf '%s\n' "$line" >>"$conf"
}

# Add the TUN device cgroup rule and bind mount to an LXC config when missing.
# Sets TUN_CHANGED to 1 when a line was appended, 0 when nothing changed.
# Returns 1 without touching TUN_CHANGED when the config is missing or a
# write fails, so callers never assume the device is configured.
ensure_tun_config() {
  local conf="$1" changed=0
  local cgroup='lxc.cgroup2.devices.allow: c 10:200 rwm'
  local mount='lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'
  [[ -f "$conf" ]] || return 1
  if ! grep -qE 'lxc\.cgroup2\.devices\.allow:[[:space:]]*c 10:200 rwm' "$conf" 2>/dev/null; then
    _tun_append "$conf" "$cgroup" || return 1
    changed=1
  fi
  if ! grep -qE 'lxc\.mount\.entry:[[:space:]]*/dev/net/tun[[:space:]]+dev/net/tun[[:space:]]+none[[:space:]]+bind,create=file' "$conf" 2>/dev/null; then
    _tun_append "$conf" "$mount" || return 1
    changed=1
  fi
  TUN_CHANGED="$changed"
  return 0
}

# Map service manager facts (1/0 each) to the backend name.
backend_from_facts() {
  local has_systemd="$1" has_openrc="$2" has_supervise="$3"
  if [[ "$has_systemd" == 1 ]]; then
    echo systemd
  elif [[ "$has_openrc" == 1 && "$has_supervise" == 1 ]]; then
    echo openrc
  else
    echo none
  fi
}

# Detect the service manager on the current host.
service_backend() {
  local has_systemd=0 has_openrc=0 has_supervise=0
  if [[ -d /run/systemd/system ]]; then
    has_systemd=1
  fi
  if command -v rc-service >/dev/null 2>&1; then
    has_openrc=1
  fi
  if command -v supervise-daemon >/dev/null 2>&1; then
    has_supervise=1
  fi
  backend_from_facts "$has_systemd" "$has_openrc" "$has_supervise"
}

# Succeed when a version is at least the given minimum version.
_cli_version_ge() {
  local version="$1" min="$2" i a b
  local -a v m
  IFS='.' read -r -a v <<<"$version"
  IFS='.' read -r -a m <<<"$min"
  for i in 0 1 2; do
    a="${v[i]:-0}"
    b="${m[i]:-0}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    a=$((10#$a))
    b=$((10#$b))
    if ((a > b)); then return 0; fi
    if ((a < b)); then return 1; fi
  done
  return 0
}

# Succeed when the state file records this version and the installed binary
# still matches the recorded sha256.
cli_state_matches() {
  local version="$1" state_version state_sha
  [[ -n "$version" && -f "$PANGOLIN_STATE_FILE" && -f "$PANGOLIN_BIN" ]] || return 1
  state_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PANGOLIN_STATE_FILE" |
    head -n 1)"
  state_sha="$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PANGOLIN_STATE_FILE" |
    head -n 1)"
  [[ "$state_version" == "$version" && -n "$state_sha" ]] || return 1
  verify_sha256 "$PANGOLIN_BIN" "$state_sha"
}

# Record the accepted CLI artifact in PANGOLIN_STATE_FILE with mode 0644.
write_cli_state() {
  local version="$1" asset="$2" sha256="$3" dir tmp
  dir="$(dirname "$PANGOLIN_STATE_FILE")"
  install -d -m 0755 "$dir" || return 1
  tmp="$(mktemp "$dir/.cli.json.XXXXXX")" || return 1
  chmod 0644 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! printf '{"version":"%s","asset":"%s","sha256":"%s"}\n' \
    "$(json_escape "$version")" "$(json_escape "$asset")" "$(json_escape "$sha256")" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$PANGOLIN_STATE_FILE"
}

# Print the Fossorial CLI release metadata.
_cli_release_api() {
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 "$PANGOLIN_RELEASE_API"
}

# Restore a file's SELinux context when SELinux is enforcing. A missing
# restorecon is a warning, never an install failure.
restore_selinux_context() {
  local path="$1"
  [[ -e "$PANGOLIN_SELINUX_ENFORCE" ]] || return 0
  if ! command -v restorecon >/dev/null 2>&1; then
    echo "SELinux is enforcing but restorecon is not installed; $path may not be executable by systemd." >&2
    return 0
  fi
  if ! restorecon "$path"; then
    echo "Failed to restore the SELinux context of $path" >&2
  fi
  return 0
}

# Install the Pangolin CLI only after its sha256 and version are verified.
# Returns 1 on any failure and leaves the existing binary untouched.
install_cli_binary() {
  local target="${1:-latest}" pinned="${2:--}" version asset digest api_json="" latest
  local tmp="" actual bin_dir arch
  local min_version="0.21.0"

  case "$target" in
  latest) ;;
  *)
    if ! _cli_version_ge "$target" "$min_version"; then
      echo "Unsupported Pangolin CLI version: $target (minimum $min_version)" >&2
      return 1
    fi
    version="$target"
    ;;
  esac

  arch="$(detect_arch)" || return 1
  asset="pangolin-cli_linux_$arch"

  if [[ "$target" == latest ]]; then
    api_json="$(_cli_release_api)" || {
      echo "Failed to fetch Pangolin CLI release metadata from $PANGOLIN_RELEASE_API" >&2
      return 1
    }
    version="$(release_version "$api_json")" || {
      echo "Pangolin CLI release metadata has no latestVersion" >&2
      return 1
    }
  fi

  if ! _cli_version_ge "$version" "$min_version"; then
    echo "Unsupported Pangolin CLI version: $version (minimum $min_version)" >&2
    return 1
  fi

  if cli_state_matches "$version"; then
    echo "Pangolin CLI $version is already installed and verified."
    return 0
  fi

  if [[ -n "$pinned" && "$pinned" != "-" ]]; then
    digest="$pinned"
  elif [[ -n "${var_pangolin_cli_sha256:-}" ]]; then
    digest="$var_pangolin_cli_sha256"
  else
    if [[ -z "$api_json" ]]; then
      api_json="$(_cli_release_api)" || {
        echo "Failed to fetch Pangolin CLI release metadata from $PANGOLIN_RELEASE_API" >&2
        return 1
      }
    fi
    latest="$(release_version "$api_json")" || latest=""
    if [[ -z "$latest" ]]; then
      echo "Pangolin CLI release metadata has no latestVersion" >&2
      return 1
    fi
    if [[ "$version" != "$latest" ]]; then
      echo "Pinned Pangolin CLI version $version differs from latest $latest; set var_pangolin_cli_sha256." >&2
      return 1
    fi
    digest="$(release_digest "$api_json" "$asset")" || {
      echo "No sha256 for $asset in the Pangolin CLI release metadata" >&2
      return 1
    }
  fi

  if [[ -z "$digest" ]]; then
    echo "Empty sha256 for $asset $version; refusing to install." >&2
    return 1
  fi

  # Prepare both directories before replacing the live binary, so a bad state
  # path fails while the old binary is still intact.
  install -d -m 0755 "$(dirname "$PANGOLIN_STATE_FILE")" || return 1
  bin_dir="$(dirname "$PANGOLIN_BIN")"
  install -d -m 0755 "$bin_dir" || return 1
  tmp="$(mktemp "$bin_dir/.pangolin-cli.XXXXXX")" || {
    echo "Cannot create a temporary file beside $PANGOLIN_BIN" >&2
    return 1
  }
  if ! curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
    "$PANGOLIN_RELEASE_BASE/$version/$asset" -o "$tmp"; then
    rm -f "$tmp"
    echo "Failed to download $asset $version" >&2
    return 1
  fi
  if ! verify_sha256 "$tmp" "$digest"; then
    rm -f "$tmp"
    echo "sha256 mismatch for $asset $version; keeping the existing binary." >&2
    return 1
  fi
  if ! chmod 755 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! actual="$("$tmp" version 2>/dev/null)"; then
    rm -f "$tmp"
    echo "$asset $version does not run; keeping the existing binary." >&2
    return 1
  fi
  if [[ "$actual" != "$version" ]]; then
    rm -f "$tmp"
    echo "$asset reports version $actual, expected $version; keeping the existing binary." >&2
    return 1
  fi
  # Record the verified artifact before replacing the binary. If the state write
  # fails the old binary stays in place. If the later mv fails, the orphan
  # record cannot vouch for the old binary because cli_state_matches re-hashes
  # PANGOLIN_BIN.
  if ! write_cli_state "$version" "$asset" "$digest"; then
    rm -f "$tmp"
    echo "Verified Pangolin CLI $version but failed to write $PANGOLIN_STATE_FILE; keeping the existing binary." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$PANGOLIN_BIN"; then
    rm -f "$tmp"
    echo "Failed to replace $PANGOLIN_BIN with Pangolin CLI $version" >&2
    return 1
  fi
  restore_selinux_context "$PANGOLIN_BIN"
  echo "Installed Pangolin CLI $version"
}

# Wait until the named service is active, or fail after the given attempts.
# Sleeps delay seconds between attempts, with no sleep after the last one.
wait_service_active() {
  local backend="$1" name="$2" attempts="$3" delay="$4" i=0
  [[ "$attempts" =~ ^[0-9]+$ ]] || return 1
  attempts=$((10#$attempts))
  while ((i < attempts)); do
    case "$backend" in
    systemd)
      if systemctl is-active --quiet "$name" >/dev/null 2>&1; then
        return 0
      fi
      ;;
    openrc)
      if rc-service "$name" status >/dev/null 2>&1; then
        return 0
      fi
      ;;
    *)
      return 1
      ;;
    esac
    i=$((i + 1))
    if ((i < attempts)); then
      sleep "$delay"
    fi
  done
  return 1
}

# Wait until the site configuration holds credentials instead of a
# provisioning key, or fail after the given attempts.
wait_for_provisioning() {
  local config_path="$1" attempts="$2" delay="$3" i=0
  [[ "$attempts" =~ ^[0-9]+$ ]] || return 1
  attempts=$((10#$attempts))
  while ((i < attempts)); do
    if site_config_has_credentials "$config_path"; then
      return 0
    fi
    i=$((i + 1))
    if ((i < attempts)); then
      sleep "$delay"
    fi
  done
  return 1
}

# Stop the named service with the service manager that owns it.
stop_service() {
  local backend="$1" name="$2"
  case "$backend" in
  systemd) systemctl stop "$name" ;;
  openrc) rc-service "$name" stop ;;
  *) return 1 ;;
  esac
}

# Install the site service with the verified CLI, then wait for it to become
# active. Returns 1 without printing success when the install or wait fails.
install_site_systemd() {
  local config_path="$1"
  if ! "$PANGOLIN_BIN" service install site --config-file "$config_path"; then
    echo "Failed to install the pangolin-site service" >&2
    return 1
  fi
  if ! wait_service_active systemd pangolin-site 30 1; then
    echo "The pangolin-site service did not become active" >&2
    return 1
  fi
}

# Install the client service with the verified CLI, then wait for it to become
# active. Returns 1 without printing success when the install or wait fails.
# The CLI takes credentials on its command line because it has no config-file
# option; that install-time argv exposure is a known upstream limitation.
install_client_systemd() {
  local id="$1" secret="$2" endpoint="$3"
  if ! "$PANGOLIN_BIN" service install client \
    --id "$id" --secret "$secret" --endpoint "$endpoint"; then
    echo "Failed to install the pangolin-client service" >&2
    return 1
  fi
  if ! wait_service_active systemd pangolin-client 30 1; then
    echo "The pangolin-client service did not become active" >&2
    return 1
  fi
}

# Fail with an actionable message when OpenRC cannot supervise a service.
_require_supervise_daemon() {
  if ! command -v supervise-daemon >/dev/null 2>&1; then
    echo "OpenRC supervise-daemon is required for restart supervision; install the openrc package." >&2
    return 1
  fi
}

# Quote a value as a single-quoted POSIX shell word, escaping embedded quotes.
_shell_single_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Write an OpenRC unit that runs a wrapper under supervise-daemon.
_write_openrc_unit() {
  local name="$1" description="$2" command_path="$3" log_path="$4" unit
  unit="$(p "/etc/init.d/$name")"
  install -d -m 0755 "$(dirname "$unit")" || return 1
  if ! cat >"$unit" <<EOF
#!/sbin/openrc-run
name="$name"
description="$description"
supervisor=supervise-daemon
command="$command_path"
command_user=root
respawn_delay=2
respawn_max=0
output_log="$log_path"
error_log="$log_path"
depend() { need net; after firewall; }
EOF
  then
    echo "Failed to write $unit" >&2
    return 1
  fi
  chmod 0755 "$unit"
}

# Write the site wrapper and its OpenRC unit. The wrapper passes the JSON
# configuration path to the CLI through CONFIG_FILE.
write_site_openrc() {
  local config_path="$1" wrapper log_path
  _require_supervise_daemon || return 1
  wrapper="$(p /usr/local/bin/pangolin-site-start)"
  log_path="$(p /var/log/pangolin-site.log)"
  install -d -m 0755 "$(dirname "$wrapper")" "$(dirname "$log_path")" || return 1
  install -m 0700 /dev/null "$wrapper" || return 1
  if ! cat >"$wrapper" <<EOF
#!/bin/sh
CONFIG_FILE=$config_path
export CONFIG_FILE
exec "$PANGOLIN_BIN" up site
EOF
  then
    echo "Failed to write $wrapper" >&2
    return 1
  fi
  _write_openrc_unit pangolin-site "Pangolin Site (CLI)" "$wrapper" "$log_path"
}

# Write the client env file, wrapper, and OpenRC unit. The secret stays in the
# mode 0600 env file; the wrapper only sources it. Values are single-quoted so
# the sourced file cannot split or execute shell metacharacters.
write_client_openrc() {
  local id="$1" secret="$2" endpoint="$3" env_file wrapper log_path
  _require_supervise_daemon || return 1
  env_file="$(p /etc/pangolin/pangolin-client.env)"
  wrapper="$(p /usr/local/bin/pangolin-client-start)"
  log_path="$(p /var/log/pangolin-client.log)"
  install -d -m 0755 "$(dirname "$env_file")" "$(dirname "$wrapper")" "$(dirname "$log_path")" ||
    return 1
  install -m 0600 /dev/null "$env_file" || return 1
  {
    printf 'PANGOLIN_CLIENT_ID='
    _shell_single_quote "$id"
    printf '\nPANGOLIN_CLIENT_SECRET='
    _shell_single_quote "$secret"
    printf '\nPANGOLIN_ENDPOINT='
    _shell_single_quote "$endpoint"
    printf '\n'
  } >"$env_file" || return 1
  install -m 0700 /dev/null "$wrapper" || return 1
  if ! cat >"$wrapper" <<EOF
#!/bin/sh
set -a
. "$env_file"
set +a
exec "$PANGOLIN_BIN" up client --attach
EOF
  then
    echo "Failed to write $wrapper" >&2
    return 1
  fi
  _write_openrc_unit pangolin-client "Pangolin Client (CLI)" "$wrapper" "$log_path"
}

# Enable and start an OpenRC service, then wait for it to become active.
_start_openrc_service() {
  local name="$1"
  if ! rc-update add "$name" default; then
    echo "Failed to enable the $name service" >&2
    return 1
  fi
  if ! rc-service "$name" start; then
    echo "Failed to start the $name service" >&2
    return 1
  fi
  if ! wait_service_active openrc "$name" 30 1; then
    echo "The $name service did not become active" >&2
    return 1
  fi
}

# Install the site OpenRC service, then wait for it to become active.
install_site_openrc() {
  local config_path="$1"
  write_site_openrc "$config_path" || return 1
  _start_openrc_service pangolin-site
}

# Install the client OpenRC service, then wait for it to become active.
install_client_openrc() {
  local id="$1" secret="$2" endpoint="$3"
  write_client_openrc "$id" "$secret" "$endpoint" || return 1
  _start_openrc_service pangolin-client
}

# The full addon entry point is added in Task 10.
payload_main() {
  echo "pangolin-payload.sh is a library. Run tools/addon/add-pangolin.sh instead." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  payload_main "$@"
fi
