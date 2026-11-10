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

# The full addon entry point is added in Task 10.
payload_main() {
  echo "pangolin-payload.sh is a library. Run tools/addon/add-pangolin.sh instead." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  payload_main "$@"
fi
