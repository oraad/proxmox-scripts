#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
#
# Shared Pangolin addon payload. Source this file; do not execute it.
# It provides architecture detection, release metadata parsing, and sha256
# verification used by the addon entry point and its tests.

PANGOLIN_ROOT="${PANGOLIN_ROOT:-}"
p() { printf '%s%s' "$PANGOLIN_ROOT" "$1"; }

# Migration state shared with the entry point. The legacy file lists record
# what migrate_existing_addon saw, so cleanup only removes what it observed.
MIGRATED_OLD_SITE=0
MIGRATED_OLD_CLIENT=0
LEGACY_NEWT_ID=""
LEGACY_NEWT_SECRET=""
LEGACY_ENDPOINT=""
LEGACY_SITE_FILES=()
LEGACY_CLIENT_FILES=()
LEGACY_SITE_BACKUP_DIR=""
LEGACY_CLIENT_BACKUP_DIR=""
# Pre-install backups of same-named upstream files, used only when a component
# fails verification and the previous unit must be restored.
SITE_INSTALL_BACKUP_DIR=""
CLIENT_INSTALL_BACKUP_DIR=""
SITE_INSTALL_WAS_ACTIVE=0
CLIENT_INSTALL_WAS_ACTIVE=0

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
# An existing parent keeps its mode; the caller owns the directory policy.
write_private_file() {
  local path="$1" content="$2" dir
  dir="$(dirname "$path")"
  if [[ ! -d "$dir" ]]; then
    install -d -m 0755 "$dir" || return 1
  fi
  install -m 0600 /dev/null "$path" || return 1
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

# Print the value of KEY from a KEY=value file, removing one layer of matching
# single or double quotes. Returns 1 when the key is absent or empty.
_env_value() {
  local file="$1" key="$2" line value
  [[ -f "$file" ]] || return 1
  line="$(sed -n "s/^[[:space:]]*$key=//p" "$file" | tail -n 1)"
  [[ -n "$line" ]] || return 1
  case "$line" in
  \'*\') value="${line#\'}"; value="${value%\'}" ;;
  \"*\") value="${line#\"}"; value="${value%\"}" ;;
  *) value="$line" ;;
  esac
  printf '%s' "$value"
}

# Copy existing paths into a new timestamped directory under
# /var/lib/pangolin/backup and print that directory. A manifest records each
# original path so restore can put the file back where it came from. Missing
# paths are skipped; names that collide are prefixed with a counter.
backup_existing() {
  local root stamp dir src base name n
  root="$(p /var/lib/pangolin/backup)"
  install -d -m 0700 "$root" || return 1
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$root/$stamp"
  n=2
  while [[ -e "$dir" ]]; do
    dir="$root/$stamp-$n"
    n=$((n + 1))
  done
  install -d -m 0700 "$dir" || return 1
  : >"$dir/manifest" || return 1
  chmod 0600 "$dir/manifest" || return 1
  for src in "$@"; do
    [[ -e "$src" || -L "$src" ]] || continue
    base="$(basename "$src")"
    name="$base"
    n=2
    while [[ -e "$dir/$name" ]]; do
      name="$n-$base"
      n=$((n + 1))
    done
    if ! cp -a "$src" "$dir/$name"; then
      echo "Failed to back up $src" >&2
      return 1
    fi
    printf '%s\t%s\n' "$name" "$src" >>"$dir/manifest" || return 1
  done
  printf '%s\n' "$dir"
}

# Validate a backup manifest before restore touches any destination. Every
# non-empty line must be exactly two tab-separated, non-empty fields, the
# stored name must be a plain basename, and the stored file must exist. A
# corrupt manifest fails loudly instead of restoring only the parseable lines.
_validate_backup_manifest() {
  local dir="$1" line name rest
  [[ -f "$dir/manifest" ]] || {
    echo "restore_backup: $dir has no manifest" >&2
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || {
      echo "restore_backup: empty manifest line in $dir/manifest" >&2
      return 1
    }
    [[ "$line" == *$'\t'* ]] || {
      echo "restore_backup: malformed manifest line in $dir/manifest" >&2
      return 1
    }
    name="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    [[ "$rest" != *$'\t'* ]] || {
      echo "restore_backup: too many fields in $dir/manifest" >&2
      return 1
    }
    [[ -n "$name" && -n "$rest" ]] || {
      echo "restore_backup: empty manifest field in $dir/manifest" >&2
      return 1
    }
    [[ "$name" != */* && "$name" != "." && "$name" != ".." ]] || {
      echo "restore_backup: unsafe backup name in $dir/manifest" >&2
      return 1
    }
    [[ -e "$dir/$name" || -L "$dir/$name" ]] || {
      echo "restore_backup: backup file $dir/$name is missing" >&2
      return 1
    }
  done <"$dir/manifest"
  return 0
}

# Copy every file in a backup directory back to the path recorded in its
# manifest, preserving the original mode and ownership where permitted.
restore_backup() {
  local dir="$1" line name src target parent
  if [[ ! -d "$dir" ]]; then
    echo "restore_backup: $dir is not a backup directory" >&2
    return 1
  fi
  _validate_backup_manifest "$dir" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    name="${line%%$'\t'*}"
    src="${line#*$'\t'}"
    target="$dir/$name"
    parent="$(dirname "$src")"
    if [[ ! -d "$parent" ]]; then
      install -d -m 0755 "$parent" || return 1
    fi
    if [[ -d "$target" && ! -L "$target" && -d "$src" ]]; then
      cp -a "$target/." "$src/" || return 1
    else
      cp -a "$target" "$src" || return 1
    fi
  done <"$dir/manifest"
}

# Record the legacy addon paths that exist, grouped by the component that owns
# them. The current site wrapper has the same path on OpenRC, so cleanup checks
# its content before removing it.
_record_legacy_paths() {
  local path
  LEGACY_SITE_FILES=()
  LEGACY_CLIENT_FILES=()
  for path in "$(p /etc/pangolin/pangolin-site.env)" \
    "$(p /usr/local/bin/pangolin-site-start)" \
    "$(p /root/.pangolin-cli)"; do
    if [[ -e "$path" || -L "$path" ]]; then
      LEGACY_SITE_FILES+=("$path")
    fi
  done
  for path in "$(p /etc/pangolin-cli/client.env)" \
    "$(p /etc/systemd/system/pangolin-cli.service)" \
    "$(p /etc/init.d/pangolin-cli)" \
    "$(p /usr/local/bin/pangolin-cli-start)" \
    "$(p /root/.pangolin-cli)"; do
    if [[ -e "$path" || -L "$path" ]]; then
      LEGACY_CLIENT_FILES+=("$path")
    fi
  done
}

# Read standalone Newt credentials for the entry point. Nothing is removed
# here: Newt files are only cleaned after the replacement site is verified.
migrate_legacy_newt() {
  local env
  LEGACY_NEWT_ID=""
  LEGACY_NEWT_SECRET=""
  LEGACY_ENDPOINT=""
  env="$(p /etc/newt/newt.env)"
  [[ -f "$env" ]] || return 0
  LEGACY_NEWT_ID="$(_env_value "$env" NEWT_ID || true)"
  LEGACY_NEWT_SECRET="$(_env_value "$env" NEWT_SECRET || true)"
  LEGACY_ENDPOINT="$(_env_value "$env" PANGOLIN_ENDPOINT || true)"
  return 0
}

# Remove a standalone Newt installation only after the replacement site is
# verified. Files are backed up first; a failed backup removes nothing. The
# Alpine `newt` dialog package is not touched: only /usr/local/bin/newt is the
# Pangolin binary.
cleanup_legacy_newt() {
  local path backup_dir
  local -a paths=()
  for path in "$(p /etc/newt/newt.env)" \
    "$(p /usr/local/bin/newt)" "$(p /usr/local/bin/newt-start)" \
    "$(p /usr/bin/update-newt)" "$(p /root/.newt)" \
    "$(p /etc/systemd/system/newt.service)" "$(p /etc/init.d/newt)"; do
    if [[ -e "$path" || -L "$path" ]]; then
      paths+=("$path")
    fi
  done
  if ((${#paths[@]} == 0)); then
    return 0
  fi
  if [[ -z "$PANGOLIN_ROOT" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now newt >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
      rc-service newt stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del newt default >/dev/null 2>&1 || true
    fi
  fi
  if ! backup_dir="$(backup_existing "${paths[@]}")"; then
    echo "Failed to back up legacy Newt files; refusing to remove them" >&2
    return 1
  fi
  for path in "${paths[@]}"; do
    if ! rm -f "$path"; then
      echo "Failed to remove $path" >&2
      return 1
    fi
  done
  rmdir "$(p /etc/newt)" 2>/dev/null || true
  if [[ -z "$PANGOLIN_ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  echo "Removed the legacy Newt installation (backup: $backup_dir)."
}

# Convert the current addon's site and client files into the new layout. Old
# files are only recorded, never removed; the entry point calls
# cleanup_legacy_addon after each component verifies.
migrate_existing_addon() {
  local old_site new_site old_client new_client id secret endpoint cid csecret cendpoint
  local content
  MIGRATED_OLD_SITE=0
  MIGRATED_OLD_CLIENT=0
  _record_legacy_paths

  old_site="$(p /etc/pangolin/pangolin-site.env)"
  new_site="$(p /etc/pangolin/site.json)"
  if [[ -f "$old_site" ]]; then
    id="$(_env_value "$old_site" SITE_ID || true)"
    secret="$(_env_value "$old_site" SITE_SECRET || true)"
    endpoint="$(_env_value "$old_site" PANGOLIN_ENDPOINT || true)"
    if [[ -n "$id" && -n "$secret" && -n "$endpoint" ]]; then
      if [[ ! -f "$new_site" ]]; then
        write_private_file "$new_site" "$(site_config_static "$endpoint" "$id" "$secret")" ||
          return 1
        MIGRATED_OLD_SITE=1
      fi
    else
      echo "Legacy $old_site is incomplete; leaving it in place." >&2
    fi
  fi

  old_client="$(p /etc/pangolin-cli/client.env)"
  new_client="$(p /etc/pangolin/pangolin-client.env)"
  if [[ -f "$old_client" ]]; then
    cid="$(_env_value "$old_client" PANGOLIN_CLIENT_ID || true)"
    csecret="$(_env_value "$old_client" PANGOLIN_CLIENT_SECRET || true)"
    cendpoint="$(_env_value "$old_client" PANGOLIN_ENDPOINT || true)"
    if [[ -n "$cid" && -n "$csecret" && -n "$cendpoint" ]]; then
      if [[ ! -f "$new_client" ]]; then
        content="$(printf 'PANGOLIN_CLIENT_ID=%s\nPANGOLIN_CLIENT_SECRET=%s\nPANGOLIN_ENDPOINT=%s' \
          "$(_shell_single_quote "$cid")" "$(_shell_single_quote "$csecret")" \
          "$(_shell_single_quote "$cendpoint")")"
        write_private_file "$new_client" "$content" || return 1
        MIGRATED_OLD_CLIENT=1
      fi
    else
      echo "Legacy $old_client is incomplete; leaving it in place." >&2
    fi
  fi
  return 0
}

# Remove the old site wrapper only when it still sources the legacy env file.
# OpenRC installs the replacement at the same path, so its content decides.
_remove_legacy_site_wrapper() {
  local wrapper="$1"
  [[ -f "$wrapper" ]] || return 0
  if grep -q '/etc/pangolin/pangolin-site.env' "$wrapper" 2>/dev/null; then
    if ! rm -f "$wrapper"; then
      echo "Failed to remove $wrapper" >&2
      return 1
    fi
  fi
  return 0
}

# Stop and disable the old client service before its unit is removed. Skipped
# under PANGOLIN_ROOT so tests never touch the host's service manager.
_stop_legacy_client_service() {
  [[ -z "$PANGOLIN_ROOT" ]] || return 0
  if [[ -f "$(p /etc/systemd/system/pangolin-cli.service)" ]] &&
    command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now pangolin-cli >/dev/null 2>&1 || true
  fi
  if [[ -f "$(p /etc/init.d/pangolin-cli)" ]]; then
    if command -v rc-service >/dev/null 2>&1; then
      rc-service pangolin-cli stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
      rc-update del pangolin-cli default >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# Remove the recorded legacy files for the components verified in this run.
# An unknown scope fails before touching anything. Each scope first backs up
# the files it is about to remove, so the rollback path never depends on the
# caller remembering to do it. If that backup fails, nothing is removed.
# Old client files are only removed when the new client is verified; site and
# client are independent.
cleanup_legacy_addon() {
  local scope="${1:-}" path backup_dir rc=0 site_wrapper
  local -a paths=()
  case "$scope" in
  site | client | both) ;;
  *)
    echo "cleanup_legacy_addon: expected site, client, or both" >&2
    return 1
    ;;
  esac
  if [[ "$scope" == site || "$scope" == both ]]; then
    LEGACY_SITE_BACKUP_DIR=""
    paths=()
    site_wrapper="$(p /usr/local/bin/pangolin-site-start)"
    if [[ ${#LEGACY_SITE_FILES[@]} -gt 0 ]]; then
      for path in "${LEGACY_SITE_FILES[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
          paths+=("$path")
        fi
      done
    fi
    if [[ ${#paths[@]} -gt 0 ]]; then
      if ! backup_dir="$(backup_existing "${paths[@]}")"; then
        echo "Failed to back up legacy site files; refusing to remove them" >&2
        return 1
      fi
      LEGACY_SITE_BACKUP_DIR="$backup_dir"
      for path in "${paths[@]}"; do
        if [[ "$path" == "$site_wrapper" ]]; then
          _remove_legacy_site_wrapper "$path" || rc=1
        elif ! rm -f "$path"; then
          echo "Failed to remove $path" >&2
          rc=1
        fi
      done
    fi
  fi
  if [[ "$scope" == client || "$scope" == both ]]; then
    LEGACY_CLIENT_BACKUP_DIR=""
    _stop_legacy_client_service
    paths=()
    if [[ ${#LEGACY_CLIENT_FILES[@]} -gt 0 ]]; then
      for path in "${LEGACY_CLIENT_FILES[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
          paths+=("$path")
        fi
      done
    fi
    if [[ ${#paths[@]} -gt 0 ]]; then
      if ! backup_dir="$(backup_existing "${paths[@]}")"; then
        echo "Failed to back up legacy client files; refusing to remove them" >&2
        return 1
      fi
      LEGACY_CLIENT_BACKUP_DIR="$backup_dir"
      for path in "${paths[@]}"; do
        if ! rm -f "$path"; then
          echo "Failed to remove $path" >&2
          rc=1
        fi
      done
    fi
    rmdir "$(p /etc/pangolin-cli)" 2>/dev/null || true
    if [[ -z "$PANGOLIN_ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
  return "$rc"
}

# Push the payload and every regular file in the answers directory into
# /root/.pangolin-addon with explicit modes. Older versions of `pct push` have
# no --perms option, so a failed push is retried without it and the mode is
# applied with chmod inside the container. File contents never enter argv.
push_payload() {
  local ctid="${1:-}" payload="${2:-}" answers="${3:-}" file base remote
  if [[ -z "$ctid" || ! -f "$payload" || ! -d "$answers" ]]; then
    echo "push_payload: expected a CTID, a payload file, and an answers directory" >&2
    return 1
  fi
  remote="/root/.pangolin-addon"
  pct exec "$ctid" -- sh -c 'mkdir -p /root/.pangolin-addon && chmod 700 /root/.pangolin-addon' ||
    return 1
  if ! pct push "$ctid" "$payload" "$remote/payload.sh" --perms 700; then
    pct push "$ctid" "$payload" "$remote/payload.sh" || return 1
    pct exec "$ctid" -- chmod 700 "$remote/payload.sh" || return 1
  fi
  for file in "$answers"/*; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    [[ "$base" == payload.sh ]] && continue
    if ! pct push "$ctid" "$file" "$remote/$base" --perms 600; then
      pct push "$ctid" "$file" "$remote/$base" || return 1
      pct exec "$ctid" -- chmod 600 "$remote/$base" || return 1
    fi
  done
}

# Replace the old pangolin-cli tag with the tags for the components installed
# in this run. Existing unrelated tags are kept and the container is only
# updated when the tag list actually changes.
apply_lxc_tags() {
  local ctid="${1:-}" site="$2" client="$3" current next
  if [[ -z "$ctid" ]]; then
    echo "apply_lxc_tags: expected a CTID" >&2
    return 1
  fi
  current="$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/ {print $2}')" || return 1
  next="$(remove_tag "$current" pangolin-cli)"
  if [[ "$site" == 1 ]]; then
    next="$(add_tag "$next" pangolin-site)"
  fi
  if [[ "$client" == 1 ]]; then
    next="$(add_tag "$next" pangolin-client)"
  fi
  [[ "$next" == "$current" ]] && return 0
  pct set "$ctid" -tags "$next"
}

# Install the site component and verify it before its legacy files are removed.
# `site_verified` records whether a verified config existed before migration, so
# new answers replace a legacy install instead of losing to the migrated file.
# Returns 1 without printing success when the service or provisioning fails.
_install_site_component() {
  local backend="$1" answers="$2" reconfigure="$3" site_verified="$4" config content
  config="$(p /etc/pangolin/site.json)"
  if [[ -f "$answers/site.json" ]] && [[ "$reconfigure" == 1 || "$site_verified" == 0 ]]; then
    content="$(<"$answers/site.json")"
    install -d -m 0755 "$(dirname "$config")" || return 1
    write_private_file "$config" "$content" || return 1
  elif [[ -f "$config" ]] &&
    { site_config_has_credentials "$config" || grep -q '"provisioningKey"[[:space:]]*:' "$config"; }; then
    chmod 0600 "$config" || return 1
    echo "Reusing the existing site configuration at $config."
  elif [[ -n "$LEGACY_NEWT_ID" && -n "$LEGACY_NEWT_SECRET" && -n "$LEGACY_ENDPOINT" ]]; then
    install -d -m 0755 "$(dirname "$config")" || return 1
    write_private_file "$config" \
      "$(site_config_static "$LEGACY_ENDPOINT" "$LEGACY_NEWT_ID" "$LEGACY_NEWT_SECRET")" ||
      return 1
  else
    echo "No site configuration to install; provide site credentials." >&2
    return 1
  fi

  case "$backend" in
  systemd) install_site_systemd "$config" || return 1 ;;
  openrc) install_site_openrc "$config" || return 1 ;;
  *) return 1 ;;
  esac
  if ! wait_for_provisioning "$config" 30 1; then
    echo "The pangolin-site service did not complete provisioning." >&2
    return 1
  fi
  chmod 0600 "$config" || return 1
  echo "Pangolin site service is installed and verified."
}

# Install the client component from the private answers file. Client
# credentials always replace the existing client service.
_install_client_component() {
  local backend="$1" answers="$2" cid csecret cendpoint client_env
  if [[ ! -f "$answers/client.env" ]]; then
    echo "No client credentials to install; client.env is missing." >&2
    return 1
  fi
  # Source the answers file so quoted secrets with apostrophes or newlines come
  # back byte-for-byte. The answers directory is mode 0700 and the file 0600.
  # shellcheck disable=SC1090,SC1091
  source "$answers/client.env"
  cid="${PANGOLIN_CLIENT_ID:-}"
  csecret="${PANGOLIN_CLIENT_SECRET:-}"
  cendpoint="${PANGOLIN_ENDPOINT:-}"
  unset PANGOLIN_CLIENT_ID PANGOLIN_CLIENT_SECRET PANGOLIN_ENDPOINT
  if [[ -z "$cid" || -z "$csecret" || -z "$cendpoint" ]]; then
    echo "Client credentials are incomplete; client.env needs an id, secret, and endpoint." >&2
    return 1
  fi

  case "$backend" in
  systemd) install_client_systemd "$cid" "$csecret" "$cendpoint" || return 1 ;;
  openrc) install_client_openrc "$cid" "$csecret" "$cendpoint" || return 1 ;;
  *) return 1 ;;
  esac
  client_env="$(p /etc/pangolin/pangolin-client.env)"
  if [[ -f "$client_env" ]]; then
    chmod 0600 "$client_env" || return 1
  fi
  echo "Pangolin client service is installed and verified."
}

# Succeed when the named service is active. Never queries a service manager
# under PANGOLIN_ROOT, so tests stay hermetic.
_service_is_active() {
  local backend="$1" name="$2"
  [[ -z "$PANGOLIN_ROOT" ]] || return 1
  case "$backend" in
  systemd) systemctl is-active --quiet "$name" >/dev/null 2>&1 ;;
  openrc) rc-service "$name" status >/dev/null 2>&1 ;;
  *) return 1 ;;
  esac
}

# Back up the same-named upstream files for one component, including the site
# configuration and OpenRC wrappers, before the installer replaces them. Only
# existing paths are included. Sets the matching *_INSTALL_BACKUP_DIR and
# *_INSTALL_WAS_ACTIVE globals.
_backup_install_paths() {
  local backend="$1" scope="$2" path backup_dir="" was_active=0 name
  local -a paths=()
  case "$scope" in
  site)
    name=pangolin-site
    SITE_INSTALL_BACKUP_DIR=""
    SITE_INSTALL_WAS_ACTIVE=0
    for path in "$(p /etc/systemd/system/pangolin-site.service)" \
      "$(p /etc/pangolin/pangolin-site.env)" "$(p /etc/pangolin/site.json)" \
      "$(p /etc/init.d/pangolin-site)" "$(p /usr/local/bin/pangolin-site-start)"; do
      if [[ -e "$path" || -L "$path" ]]; then
        paths+=("$path")
      fi
    done
    ;;
  client)
    name=pangolin-client
    CLIENT_INSTALL_BACKUP_DIR=""
    CLIENT_INSTALL_WAS_ACTIVE=0
    for path in "$(p /etc/systemd/system/pangolin-client.service)" \
      "$(p /etc/pangolin/pangolin-client.env)" "$(p /etc/init.d/pangolin-client)" \
      "$(p /usr/local/bin/pangolin-client-start)"; do
      if [[ -e "$path" || -L "$path" ]]; then
        paths+=("$path")
      fi
    done
    ;;
  *)
    return 1
    ;;
  esac
  if _service_is_active "$backend" "$name"; then
    was_active=1
  fi
  if ((${#paths[@]} > 0)); then
    backup_dir="$(backup_existing "${paths[@]}")" || return 1
  fi
  if [[ "$scope" == site ]]; then
    SITE_INSTALL_BACKUP_DIR="$backup_dir"
    SITE_INSTALL_WAS_ACTIVE="$was_active"
  else
    CLIENT_INSTALL_BACKUP_DIR="$backup_dir"
    CLIENT_INSTALL_WAS_ACTIVE="$was_active"
  fi
}

# Restore a pre-install backup and restart the previous service when it was
# active. Called only after a failed replacement.
_restore_install_paths() {
  local backend="$1" scope="$2" backup_dir was_active name rc=0
  case "$scope" in
  site)
    backup_dir="$SITE_INSTALL_BACKUP_DIR"
    was_active="$SITE_INSTALL_WAS_ACTIVE"
    name=pangolin-site
    ;;
  client)
    backup_dir="$CLIENT_INSTALL_BACKUP_DIR"
    was_active="$CLIENT_INSTALL_WAS_ACTIVE"
    name=pangolin-client
    ;;
  *) return 1 ;;
  esac
  [[ -n "$backup_dir" ]] || return 0
  if ! restore_backup "$backup_dir"; then
    echo "Failed to restore the previous $name files from $backup_dir" >&2
    return 1
  fi
  if [[ "$backend" == systemd && -z "$PANGOLIN_ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ "$was_active" == 1 ]]; then
    case "$backend" in
    systemd)
      systemctl restart "$name" || {
        echo "Restored $name files but failed to restart the previous service" >&2
        rc=1
      }
      ;;
    openrc)
      rc-service "$name" restart || {
        echo "Restored $name files but failed to restart the previous service" >&2
        rc=1
      }
      ;;
    esac
  fi
  if ((rc == 0)); then
    echo "Restored the previous $name unit and configuration."
  fi
  return "$rc"
}

# Record a component that verified in the answers directory. No secrets.
_record_verified() {
  local file="$1" component="$2"
  if ! (umask 077 && printf '%s\n' "$component" >>"$file"); then
    echo "Cannot record the verified $component component in $file" >&2
    return 1
  fi
}

# Point the operator at the failed component's log. Raw tails are deliberately
# not printed: provisioning and client logs can contain credential material.
_print_service_log_hint() {
  local backend="$1" component="$2" service="pangolin-$2"
  case "$backend" in
  systemd)
    echo "Service log: journalctl -u $service" >&2
    ;;
  openrc)
    echo "Service log: $(p /var/log/$service.log)" >&2
    ;;
  esac
  echo "Or run: pangolin service logs $component" >&2
}

# Install the selected components from a private answers directory. Components
# are independent: a verified component stays installed when the other fails,
# and the failed component is stopped without touching the earlier one.
payload_main() {
  local answers="${1:-}" flags verified_file backend site client reconfigure rc=0 site_verified=0
  if [[ -z "$answers" || ! -d "$answers" ]]; then
    echo "payload_main: an answers directory is required" >&2
    return 1
  fi
  flags="$answers/flags"
  if [[ ! -f "$flags" ]]; then
    echo "payload_main: $flags is missing" >&2
    return 1
  fi
  site="$(_env_value "$flags" SITE || true)"
  client="$(_env_value "$flags" CLIENT || true)"
  reconfigure="$(_env_value "$flags" RECONFIGURE || true)"
  if [[ "$site" != 0 && "$site" != 1 ]] || [[ "$client" != 0 && "$client" != 1 ]]; then
    echo "payload_main: flags must set SITE and CLIENT to 0 or 1" >&2
    return 1
  fi
  if [[ "$site" != 1 && "$client" != 1 ]]; then
    echo "payload_main: flags select no component" >&2
    return 1
  fi
  if [[ "$reconfigure" != 1 ]]; then
    reconfigure=0
  fi

  # Record only the components that verify, so a partial run can still tag the
  # ones that succeeded. The file holds component names, never credentials.
  verified_file="$answers/verified"
  if ! (umask 077 && : >"$verified_file"); then
    echo "Cannot create $verified_file; LXC tags may be incomplete." >&2
    rc=1
  fi

  backend="$(service_backend)" || {
    echo "Could not detect the service manager." >&2
    return 1
  }
  if [[ "$backend" == none ]]; then
    echo "No supported service manager found (systemd or OpenRC with supervise-daemon)." >&2
    return 1
  fi

  install_cli_binary "${var_pangolin_cli_version:-latest}" "${var_pangolin_cli_sha256:--}" ||
    return 1
  if [[ -f "$(p /etc/pangolin/site.json)" ]] &&
    site_config_has_credentials "$(p /etc/pangolin/site.json)"; then
    site_verified=1
  fi
  migrate_existing_addon || return 1
  if [[ "$site" == 1 ]]; then
    migrate_legacy_newt || return 1
  fi

  if [[ "$site" == 1 ]]; then
    if ! _backup_install_paths "$backend" site; then
      echo "Failed to back up the existing site unit; refusing to replace it." >&2
      rc=1
    elif _install_site_component "$backend" "$answers" "$reconfigure" "$site_verified"; then
      _record_verified "$verified_file" site || rc=1
      cleanup_legacy_addon site || {
        echo "The pangolin-site service is verified, but legacy site cleanup failed." >&2
        rc=1
      }
      cleanup_legacy_newt || {
        echo "The pangolin-site service is verified, but legacy Newt cleanup failed." >&2
        rc=1
      }
    else
      stop_service "$backend" pangolin-site >/dev/null 2>&1 || true
      _print_service_log_hint "$backend" site
      _restore_install_paths "$backend" site || rc=1
      rc=1
    fi
  fi
  if [[ "$client" == 1 ]]; then
    if ! _backup_install_paths "$backend" client; then
      echo "Failed to back up the existing client unit; refusing to replace it." >&2
      rc=1
    elif _install_client_component "$backend" "$answers"; then
      _record_verified "$verified_file" client || rc=1
      cleanup_legacy_addon client || {
        echo "The pangolin-client service is verified, but legacy client cleanup failed." >&2
        rc=1
      }
    else
      stop_service "$backend" pangolin-client >/dev/null 2>&1 || true
      _print_service_log_hint "$backend" client
      _restore_install_paths "$backend" client || rc=1
      rc=1
    fi
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  payload_main "$@"
fi
