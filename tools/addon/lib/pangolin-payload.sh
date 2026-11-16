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

# Print the JSON keys for the enabled site native modes and disabled SSH. A
# flag equal to 1 adds its boolean and interface name; disabled modes add
# nothing so the CLI defaults apply. disableSsh is appended only when it is 1:
# the SSH owner slug keeps no key and the legacy JSON stays byte-identical.
# Callers validate the values before building a configuration.
_native_config_suffix() {
  local native="${1-0}" native_main="${2-0}"
  local interface="${3-pangolin}" interface_main="${4-pangolin}"
  local disable_ssh="${5-0}" out=""
  if [[ "$native" == 1 ]]; then
    out=",\"native\":true,\"interface\":\"$(json_escape "$interface")\""
  fi
  if [[ "$native_main" == 1 ]]; then
    out+=",\"nativeMain\":true,\"interfaceMain\":\"$(json_escape "$interface_main")\""
  fi
  if [[ "$disable_ssh" == 1 ]]; then
    out+=",\"disableSsh\":true"
  fi
  printf '%s' "$out"
}

# Print a static-credential site configuration as JSON. The optional trailing
# native arguments add the kernel interface keys when a mode is enabled, and
# the disableSsh argument adds the SSH opt-out key.
site_config_static() {
  local suffix
  suffix="$(_native_config_suffix "${4-0}" "${5-0}" "${6-pangolin}" "${7-pangolin}" "${8-0}")" ||
    return 1
  printf '{"endpoint":"%s","id":"%s","secret":"%s"%s}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$suffix"
}

# Print a provisioning-key site configuration as JSON. The optional trailing
# native arguments add the kernel interface keys when a mode is enabled, and
# the disableSsh argument adds the SSH opt-out key.
site_config_provisioning() {
  local suffix
  suffix="$(_native_config_suffix "${4-0}" "${5-0}" "${6-pangolin}" "${7-pangolin}" "${8-0}")" ||
    return 1
  printf '{"endpoint":"%s","provisioningKey":"%s","name":"%s"%s}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$suffix"
}

# Succeed when a site configuration holds credentials and no provisioning key.
site_config_has_credentials() {
  local path="$1"
  grep -q '"id"[[:space:]]*:' "$path" &&
    grep -q '"secret"[[:space:]]*:' "$path" &&
    ! grep -q '"provisioningKey"[[:space:]]*:' "$path"
}

# Print the directory that holds the per-slug site configurations. The single
# legacy site stays at /etc/pangolin/site.json.
site_config_dir() {
  p /etc/pangolin/sites
}

# Succeed when the argument is a valid local site slug: 1-10 characters,
# a lowercase letter first, lowercase letters, digits, and inner hyphens.
# Payload callers validate through this before any path or unit name is
# built, so traversal and slash-bearing input can never reach a file
# operation.
_is_site_slug() {
  local slug="${1:-}"
  [[ "$slug" =~ ^[a-z]([a-z0-9-]{0,8}[a-z0-9])?$ ]]
}

# Print the configuration path for one validated slug, mode 0600 when
# written. An invalid slug fails before any path is produced.
site_config_path() {
  local slug="${1:-}"
  if ! _is_site_slug "$slug"; then
    echo "site_config_path: invalid site slug: ${slug//[[:cntrl:]]/}" >&2
    return 1
  fi
  p "/etc/pangolin/sites/$slug.json"
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
  # `pangolin version` also prints a desktop-client banner on some releases.
  # Take the last non-empty line, which is the actual version.
  if ! actual="$("$tmp" version 2>/dev/null | tr -d '\r' | awk 'NF { last = $0 } END { print last }')"; then
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

# Restart a service that was already active before an install. Upstream
# `systemctl enable --now` and `rc-service start` leave an active unit running,
# so new configuration would otherwise only take effect after a manual restart.
# Fresh installs pass was_active=0 and are left to the install path, so an
# in-flight provisioning exchange is not interrupted.
_restart_if_was_active() {
  local backend="$1" name="$2" was_active="$3"
  [[ "$was_active" == 1 ]] || return 0
  case "$backend" in
  systemd)
    systemctl restart "$name" || {
      echo "Failed to restart the $name service" >&2
      return 1
    }
    ;;
  openrc)
    rc-service "$name" restart || {
      echo "Failed to restart the $name service" >&2
      return 1
    }
    ;;
  *) return 1 ;;
  esac
}

# Install the site service with the verified CLI, then wait for it to become
# active. An already-active unit is restarted so the new configuration takes
# effect. Returns 1 without printing success when install, restart, or wait
# fails.
install_site_systemd() {
  local config_path="$1" was_active="${2:-0}"
  if ! "$PANGOLIN_BIN" service install site --config-file "$config_path"; then
    echo "Failed to install the pangolin-site service" >&2
    return 1
  fi
  if ! _restart_if_was_active systemd pangolin-site "$was_active"; then
    return 1
  fi
  if ! wait_service_active systemd pangolin-site 30 1; then
    echo "The pangolin-site service did not become active" >&2
    return 1
  fi
}

# Print the systemd template instance name for a validated slug.
site_systemd_instance() {
  printf 'pangolin-site@%s' "$1"
}

# Succeed while the template instance for a slug is active. The conversion
# path records this before touching the service so only running instances are
# restarted afterwards.
site_instance_was_active() {
  systemctl is-active --quiet "$(site_systemd_instance "$1")" >/dev/null 2>&1
}

# Write the shared pangolin-site@.service template, mirroring the upstream
# single-instance unit: same dependencies, restart policy, and sandboxing. The
# in-unit CONFIG_FILE is the literal production path with %i so systemd
# resolves it per instance; only the installed binary location is expanded.
# The per-slug config directory is created mode 0700 next to it.
write_site_systemd_template() {
  local dir unit
  dir="$(site_config_dir)"
  unit="$(p /etc/systemd/system/pangolin-site@.service)"
  install -d -m 0755 "$(dirname "$dir")" "$(dirname "$unit")" || return 1
  ensure_site_config_dir || return 1
  if ! cat >"$unit" <<EOF
[Unit]
Description=Pangolin Site (CLI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=CONFIG_FILE=/etc/pangolin/sites/%i.json
ExecStart=$PANGOLIN_BIN up site
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  then
    echo "Failed to write $unit" >&2
    return 1
  fi
  chmod 0644 "$unit" || return 1
  if ! systemctl daemon-reload; then
    echo "Failed to reload systemd after writing $unit" >&2
    return 1
  fi
  return 0
}

# Enable and start a template instance, restarting it when the slug's service
# was already active so the new configuration takes effect.
_enable_site_instance() {
  local instance="$1" was_active="${2:-0}"
  if ! systemctl enable --now "$instance"; then
    echo "Failed to enable the $instance service" >&2
    return 1
  fi
  _restart_if_was_active systemd "$instance" "$was_active"
}

# Wait for a slug's instance to become active, then for its configuration to
# hold credentials instead of a provisioning key. The policy is 30x1s; the
# internal PANGOLIN_SERVICE_ATTEMPTS and PANGOLIN_SERVICE_DELAY overrides
# exist only so the test suite runs without sleeping.
verify_site_systemd_slug() {
  local slug="$1" config_path="$2" instance
  local attempts="${PANGOLIN_SERVICE_ATTEMPTS:-30}" delay="${PANGOLIN_SERVICE_DELAY:-1}"
  instance="$(site_systemd_instance "$slug")"
  if ! wait_service_active systemd "$instance" "$attempts" "$delay"; then
    echo "The $instance service did not become active" >&2
    return 1
  fi
  if ! wait_for_provisioning "$config_path" "$attempts" "$delay"; then
    echo "The $instance service did not complete provisioning." >&2
    return 1
  fi
}

# Start a slug's template instance against its per-slug configuration, then
# verify it. was_active=1 restarts the instance after enabling.
start_site_systemd_slug() {
  local slug="$1" was_active="${2:-0}"
  _enable_site_instance "$(site_systemd_instance "$slug")" "$was_active" || return 1
  verify_site_systemd_slug "$slug" "$(site_config_path "$slug")"
}

# Stop a slug's template instance.
stop_site_systemd_slug() {
  stop_service systemd "$(site_systemd_instance "$1")"
}

# Stop an active instance, disable it, and remove the enabled instance symlink
# that `systemctl enable` leaves under multi-user.target.wants. The template
# and the per-slug config stay in place.
disable_site_systemd_slug() {
  local slug="$1" instance link
  instance="$(site_systemd_instance "$slug")"
  link="$(p "/etc/systemd/system/multi-user.target.wants/$instance.service")"
  if systemctl is-active --quiet "$instance" >/dev/null 2>&1; then
    stop_site_systemd_slug "$slug" || {
      echo "Failed to stop the $instance service" >&2
      return 1
    }
  fi
  if ! systemctl disable "$instance"; then
    echo "Failed to disable the $instance service" >&2
    return 1
  fi
  if ! rm -f "$link"; then
    echo "Failed to remove $link" >&2
    return 1
  fi
  return 0
}

# Remove a slug's instance: disabled, unlinked, and cleared from systemd's
# failed-start state. The per-slug config and the shared template are kept for
# diagnostics and other instances; callers remove those separately.
remove_site_systemd_slug() {
  local slug="$1"
  disable_site_systemd_slug "$slug" || return 1
  systemctl reset-failed "$(site_systemd_instance "$slug")" >/dev/null 2>&1 || true
  return 0
}

# Conversion building block for one slug: write the template, enable the
# instance, restart a previously-active one, and verify the service and its
# provisioning against the given configuration. This helper never touches the
# legacy single-instance unit. The revised plan requires the legacy service
# to be stopped *before* `pangolin-site@default` starts so the same site
# credentials are never active at once; Task 5 owns that ordering and calls
# retire_legacy_single_site_systemd only after `@default` verifies. On failure
# the template stays on disk for rollback.
install_site_systemd_slug() {
  local slug="$1" config_path="$2" was_active="${3:-0}"
  write_site_systemd_template || return 1
  _enable_site_instance "$(site_systemd_instance "$slug")" "$was_active" || return 1
  verify_site_systemd_slug "$slug" "$config_path"
}

# Retire the legacy single-instance unit: stop it when still running, disable
# it, and remove the unit file and its multi-user.target.wants symlink, then
# reload systemd. Only the unit plumbing is touched: the per-slug and legacy
# site configurations, credentials, and install backups stay for the caller.
# A host without a legacy install returns quietly.
retire_legacy_single_site_systemd() {
  local legacy=pangolin-site unit link
  unit="$(p "/etc/systemd/system/$legacy.service")"
  link="$(p "/etc/systemd/system/multi-user.target.wants/$legacy.service")"
  if systemctl is-active --quiet "$legacy" >/dev/null 2>&1; then
    systemctl stop "$legacy" || {
      echo "Failed to stop the $legacy service" >&2
      return 1
    }
  fi
  if [[ ! -e "$unit" && ! -L "$unit" && ! -e "$link" && ! -L "$link" ]]; then
    return 0
  fi
  if ! systemctl disable "$legacy"; then
    echo "Failed to disable the $legacy service" >&2
    return 1
  fi
  if ! rm -f "$unit" "$link"; then
    echo "Failed to remove the $legacy unit files" >&2
    return 1
  fi
  if ! systemctl daemon-reload; then
    echo "Failed to reload systemd after removing the $legacy unit" >&2
    return 1
  fi
  return 0
}

# Install the client service with the verified CLI, then wait for it to become
# active. An already-active unit is restarted so new credentials take effect.
# Returns 1 without printing success when install, restart, or wait fails.
# The CLI takes credentials on its command line because it has no config-file
# option; that install-time argv exposure is a known upstream limitation.
install_client_systemd() {
  local id="$1" secret="$2" endpoint="$3" was_active="${4:-0}"
  if ! "$PANGOLIN_BIN" service install client \
    --id "$id" --secret "$secret" --endpoint "$endpoint"; then
    echo "Failed to install the pangolin-client service" >&2
    return 1
  fi
  if ! _restart_if_was_active systemd pangolin-client "$was_active"; then
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

# Write /etc/logrotate.d/pangolin when logrotate is installed. The site glob
# covers the legacy single-instance log and every /var/log/pangolin-site-<slug>.log
# per-slug log; the client path stays literal. Both components may install first,
# so each write the full set. A write failure warns instead of failing the
# service install: log rotation is auxiliary.
_write_logrotate() {
  local file
  command -v logrotate >/dev/null 2>&1 || return 0
  file="$(p /etc/logrotate.d/pangolin)"
  install -d -m 0755 "$(dirname "$file")" || return 1
  if ! cat >"$file" <<EOF
$(p "/var/log/pangolin-site*.log")
$(p /var/log/pangolin-client.log) {
    size 10M
    rotate 5
    copytruncate
    compress
    missingok
    notifempty
}
EOF
  then
    echo "Failed to write $file" >&2
    return 1
  fi
  chmod 0644 "$file" || return 1
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
  _write_openrc_unit pangolin-site "Pangolin Site (CLI)" "$wrapper" "$log_path" || return 1
  _write_logrotate || echo "Warning: failed to write $(p /etc/logrotate.d/pangolin)" >&2
  return 0
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
  _write_openrc_unit pangolin-client "Pangolin Client (CLI)" "$wrapper" "$log_path" || return 1
  _write_logrotate || echo "Warning: failed to write $(p /etc/logrotate.d/pangolin)" >&2
  return 0
}

# Add a service to the default runlevel and start it, restarting it when it was
# already active so the new configuration takes effect. The active wait lives in
# the caller so the single-site and per-slug policies can differ.
_enable_openrc_instance() {
  local name="$1" was_active="${2:-0}"
  if ! rc-update add "$name" default; then
    echo "Failed to enable the $name service" >&2
    return 1
  fi
  if ! rc-service "$name" start; then
    echo "Failed to start the $name service" >&2
    return 1
  fi
  _restart_if_was_active openrc "$name" "$was_active"
}

# Enable and start an OpenRC service, then wait for it to become active. An
# already-active service is restarted so the new configuration takes effect.
_start_openrc_service() {
  local name="$1" was_active="${2:-0}"
  _enable_openrc_instance "$name" "$was_active" || return 1
  if ! wait_service_active openrc "$name" 30 1; then
    echo "The $name service did not become active" >&2
    return 1
  fi
}

# Install the site OpenRC service, then wait for it to become active. An
# already-active unit is restarted so the new configuration takes effect.
install_site_openrc() {
  local config_path="$1" was_active="${2:-0}"
  write_site_openrc "$config_path" || return 1
  _start_openrc_service pangolin-site "$was_active"
}

# Install the client OpenRC service, then wait for it to become active. An
# already-active unit is restarted so new credentials take effect.
install_client_openrc() {
  local id="$1" secret="$2" endpoint="$3" was_active="${4:-0}"
  write_client_openrc "$id" "$secret" "$endpoint" || return 1
  _start_openrc_service pangolin-client "$was_active"
}

# Print the OpenRC service name for a validated slug. OpenRC has no template
# units, so each slug gets its own init script named pangolin-site-<slug>.
site_openrc_instance() {
  printf 'pangolin-site-%s' "$1"
}

# Succeed while a slug's OpenRC service is active. The conversion caller records
# this before touching the service so only running services are restarted later.
site_instance_was_active_openrc() {
  rc-service "$(site_openrc_instance "$1")" status >/dev/null 2>&1
}

# Write the per-slug wrapper and its OpenRC unit. The wrapper lives under
# PANGOLIN_ROOT so tests can inspect it, but the CONFIG_FILE it exports is the
# production path with the test root stripped, so the installed wrapper points at
# the real config, never a test directory. This mirrors write_site_systemd_template
# keeping Environment=CONFIG_FILE on the literal production layout. The path is
# single-quoted so the assignment cannot split or run anything. The strip only
# happens when config_path is actually under PANGOLIN_ROOT; an unrelated path
# would silently bake a wrong CONFIG_FILE, so it is refused instead.
write_site_openrc_slug() {
  local slug="$1" config_path="$2" name wrapper log_path prod_config quoted
  _require_supervise_daemon || return 1
  name="$(site_openrc_instance "$slug")"
  wrapper="$(p "/usr/local/bin/$name-start")"
  log_path="$(p "/var/log/$name.log")"
  if [[ -n "$PANGOLIN_ROOT" ]]; then
    if [[ "$config_path" != "$PANGOLIN_ROOT"/* ]]; then
      echo "write_site_openrc_slug: $config_path is not under $PANGOLIN_ROOT" >&2
      return 1
    fi
    prod_config="${config_path#"$PANGOLIN_ROOT"}"
  else
    prod_config="$config_path"
  fi
  install -d -m 0755 "$(dirname "$wrapper")" "$(dirname "$log_path")" || return 1
  install -d -m 0700 "$(site_config_dir)" || return 1
  install -m 0700 /dev/null "$wrapper" || return 1
  quoted="$(_shell_single_quote "$prod_config")"
  if ! cat >"$wrapper" <<EOF
#!/bin/sh
CONFIG_FILE=$quoted
export CONFIG_FILE
exec "$PANGOLIN_BIN" up site
EOF
  then
    echo "Failed to write $wrapper" >&2
    return 1
  fi
  _write_openrc_unit "$name" "Pangolin Site (CLI)" "$wrapper" "$log_path" || return 1
  _write_logrotate || echo "Warning: failed to write $(p /etc/logrotate.d/pangolin)" >&2
  return 0
}

# Wait for a slug's service to become active, then for its configuration to hold
# credentials instead of a provisioning key. The policy is 30x1s; the internal
# PANGOLIN_SERVICE_ATTEMPTS and PANGOLIN_SERVICE_DELAY overrides exist only so
# the test suite runs without sleeping.
verify_site_openrc_slug() {
  local slug="$1" config_path="$2" name
  local attempts="${PANGOLIN_SERVICE_ATTEMPTS:-30}" delay="${PANGOLIN_SERVICE_DELAY:-1}"
  name="$(site_openrc_instance "$slug")"
  if ! wait_service_active openrc "$name" "$attempts" "$delay"; then
    echo "The $name service did not become active" >&2
    return 1
  fi
  if ! wait_for_provisioning "$config_path" "$attempts" "$delay"; then
    echo "The $name service did not complete provisioning." >&2
    return 1
  fi
}

# Start a slug's service against its per-slug configuration, then verify it.
# was_active=1 restarts the service after enabling so new configuration applies.
start_site_openrc_slug() {
  local slug="$1" was_active="${2:-0}"
  _enable_openrc_instance "$(site_openrc_instance "$slug")" "$was_active" || return 1
  verify_site_openrc_slug "$slug" "$(site_config_path "$slug")"
}

# Stop a slug's service.
stop_site_openrc_slug() {
  stop_service openrc "$(site_openrc_instance "$1")"
}

# Stop an active service and remove it from the default runlevel. The wrapper,
# unit, log, and per-slug config stay in place for the caller.
#
# Idempotent and command-guarded like the cleanup helpers. A service with no
# default-runlevel entry (for example a failed fresh install whose generic
# cleanup already removed the link, leaving /etc/init.d present) needs no
# `rc-update del`, and OpenRC returns non-zero for that del. So del runs only
# when /etc/runlevels/default/<name> exists, and its failure is preserved then.
# When a required command is missing the helper is a no-op, never a hard error.
disable_site_openrc_slug() {
  local slug="$1" name runlevel
  name="$(site_openrc_instance "$slug")"
  runlevel="$(p "/etc/runlevels/default/$name")"
  if command -v rc-service >/dev/null 2>&1 &&
    rc-service "$name" status >/dev/null 2>&1; then
    stop_site_openrc_slug "$slug" || {
      echo "Failed to stop the $name service" >&2
      return 1
    }
  fi
  if [[ ! -e "$runlevel" && ! -L "$runlevel" ]]; then
    return 0
  fi
  command -v rc-update >/dev/null 2>&1 || return 0
  if ! rc-update del "$name" default; then
    echo "Failed to disable the $name service" >&2
    return 1
  fi
  return 0
}

# Conversion building block for one slug: write the wrapper and unit, enable and
# start the service, restart it when it was already active, then verify the
# service and its provisioning against the given configuration. This helper never
# touches the legacy single-instance service: like install_site_systemd_slug it
# stays legacy-blind, and Task 5 orders stopping legacy before starting the
# default instance and calls retire_legacy_single_site_openrc only afterwards.
install_site_openrc_slug() {
  local slug="$1" config_path="$2" was_active="${3:-0}"
  write_site_openrc_slug "$slug" "$config_path" || return 1
  _enable_openrc_instance "$(site_openrc_instance "$slug")" "$was_active" || return 1
  verify_site_openrc_slug "$slug" "$config_path"
}

# Retire the legacy single-instance OpenRC service: stop it when still running,
# remove it from the default runlevel, and delete its init script, wrapper, and
# the default-runlevel symlink. The OpenRC enabled artifact is
# /etc/runlevels/default/pangolin-site, the sibling of the systemd wants symlink
# the systemd retire removes, so it belongs in both the existence check and the
# removal set. Only the legacy pangolin-site plumbing is touched: per-slug
# instances, the template state, the site configurations, install backups, and
# the conversion marker all stay for the caller. A host with no legacy unit,
# wrapper, or runlevel link returns quietly. Commands are guarded like the
# cleanup helpers: rc-update del runs only when the runlevel entry exists and
# rc-update is present (preserving a real del failure otherwise), and the init,
# wrapper, and runlevel files are removed under PANGOLIN_ROOT whether or not the
# service tools are on PATH.
retire_legacy_single_site_openrc() {
  local legacy=pangolin-site init wrapper runlevel
  init="$(p "/etc/init.d/$legacy")"
  wrapper="$(p "/usr/local/bin/$legacy-start")"
  runlevel="$(p "/etc/runlevels/default/$legacy")"
  if command -v rc-service >/dev/null 2>&1 &&
    rc-service "$legacy" status >/dev/null 2>&1; then
    rc-service "$legacy" stop || {
      echo "Failed to stop the $legacy service" >&2
      return 1
    }
  fi
  if [[ ! -e "$init" && ! -L "$init" && ! -e "$wrapper" && ! -L "$wrapper" &&
    ! -e "$runlevel" && ! -L "$runlevel" ]]; then
    return 0
  fi
  if [[ -e "$runlevel" || -L "$runlevel" ]] && command -v rc-update >/dev/null 2>&1; then
    if ! rc-update del "$legacy" default; then
      echo "Failed to disable the $legacy service" >&2
      return 1
    fi
  fi
  if ! rm -f "$init" "$wrapper" "$runlevel"; then
    echo "Failed to remove the $legacy service files" >&2
    return 1
  fi
  return 0
}

# Stop and disable a slug's OpenRC service, then remove its init script, its
# wrapper, and its log. The per-slug configuration and the shared logrotate
# file stay: callers remove configs only when explicitly asked.
remove_site_openrc_slug() {
  local slug="$1" name
  [[ -n "$slug" ]] || {
    echo "remove_site_openrc_slug: a slug is required" >&2
    return 1
  }
  name="$(site_openrc_instance "$slug")"
  disable_site_openrc_slug "$slug" || return 1
  if ! rm -f "$(p "/etc/init.d/$name")" "$(p "/usr/local/bin/$name-start")" \
    "$(p "/var/log/$name.log")"; then
    echo "Failed to remove the $name service files" >&2
    return 1
  fi
  return 0
}

# Remove one site instance for the given backend: stopped, disabled, and
# unlinked; on OpenRC also its unit, wrapper, and log. A systemd instance has
# no per-instance files (the template unit is shared), so only the enablement
# is removed. Configs and the shared logrotate file are preserved. The slug is
# validated before any service-manager call so an empty, traversal, or
# slash-bearing name cannot reach systemctl or rc-service.
uninstall_site_slug() {
  local backend="${1:-}" slug="${2:-}"
  [[ -n "$slug" ]] || {
    echo "uninstall_site_slug: a slug is required" >&2
    return 1
  }
  if ! _is_site_slug "$slug"; then
    echo "uninstall_site_slug: invalid site slug: ${slug//[[:cntrl:]]/}" >&2
    return 1
  fi
  case "$backend" in
  systemd) remove_site_systemd_slug "$slug" ;;
  openrc) remove_site_openrc_slug "$slug" ;;
  *)
    echo "uninstall_site_slug: expected systemd or openrc" >&2
    return 1
    ;;
  esac
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

# Succeed when the file is the old addon's site env format. The upstream CLI
# writes its own file at the same path with CONFIG_FILE=, which must survive.
_is_legacy_site_env() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -q '^[[:space:]]*SITE_ID=' "$path" 2>/dev/null ||
    grep -q '^[[:space:]]*SITE_SECRET=' "$path" 2>/dev/null
}

# Record the legacy addon paths that exist, grouped by the component that owns
# them. The current site wrapper has the same path on OpenRC, so cleanup checks
# its content before removing it. The site env path is only legacy when it
# still has the old addon format; an upstream CONFIG_FILE env belongs to the
# new service and is left alone.
_record_legacy_paths() {
  local path site_env
  site_env="$(p /etc/pangolin/pangolin-site.env)"
  LEGACY_SITE_FILES=()
  LEGACY_CLIENT_FILES=()
  for path in "$site_env" \
    "$(p /usr/local/bin/pangolin-site-start)" \
    "$(p /usr/bin/update-pangolin-site)" \
    "$(p /root/.pangolin-cli)"; do
    if [[ "$path" == "$site_env" ]]; then
      _is_legacy_site_env "$path" || continue
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
      continue
    fi
    LEGACY_SITE_FILES+=("$path")
  done
  for path in "$(p /etc/pangolin-cli/client.env)" \
    "$(p /etc/systemd/system/pangolin-cli.service)" \
    "$(p /etc/init.d/pangolin-cli)" \
    "$(p /usr/local/bin/pangolin-cli-start)" \
    "$(p /usr/bin/update-pangolin-cli)" \
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
  if _is_legacy_site_env "$old_site"; then
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

# Succeed when a path is one of the old generated updater scripts.
_is_updater_script() {
  case "$(basename "$1")" in
  update-pangolin-site | update-pangolin-cli) return 0 ;;
  *) return 1 ;;
  esac
}

# Replace an old generated updater with the one-release compatibility wrapper.
# The binary path is written literally so the installed wrapper is correct on
# the target, not under a test root.
_write_updater_wrapper() {
  local path="$1" tmp
  tmp="$(dirname "$path")/.$(basename "$path").tmp.$$"
  if ! cat >"$tmp" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/pangolin update
EOF
  then
    rm -f "$tmp"
    echo "Failed to write the updater wrapper $path" >&2
    return 1
  fi
  if ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    echo "Failed to replace $path with the updater wrapper" >&2
    return 1
  fi
}

# Remove the recorded legacy files for the components verified in this run.
# An unknown scope fails before touching anything. Each scope first backs up
# the files it is about to remove, so the rollback path never depends on the
# caller remembering to do it. If that backup fails, nothing is removed.
# Old client files are only removed when the new client is verified; site and
# client are independent.
cleanup_legacy_addon() {
  local scope="${1:-}" path backup_dir rc=0 site_wrapper site_env
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
    site_env="$(p /etc/pangolin/pangolin-site.env)"
    if [[ ${#LEGACY_SITE_FILES[@]} -gt 0 ]]; then
      for path in "${LEGACY_SITE_FILES[@]}"; do
        # The installer may have replaced the old env with the upstream
        # CONFIG_FILE form after migration recorded it. Never delete that.
        if [[ "$path" == "$site_env" ]] && ! _is_legacy_site_env "$path"; then
          continue
        fi
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
        elif _is_updater_script "$path"; then
          _write_updater_wrapper "$path" || rc=1
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
        if _is_updater_script "$path"; then
          _write_updater_wrapper "$path" || rc=1
        elif ! rm -f "$path"; then
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

# --- Multi-site layout conversion -------------------------------------------

# Print the conversion marker content (`template` or `single`) recorded under
# the state directory; return 1 when the marker is absent or unreadable. The
# marker makes the conversion one-way: it tells later runs which backend path
# to use and it prevents re-importing the legacy configuration.
_site_conversion_marker() {
  local marker value
  marker="$(p /var/lib/pangolin/site-layout)"
  [[ -f "$marker" ]] || return 1
  value="$(head -n 1 "$marker" 2>/dev/null)"
  case "$value" in
  template | single) printf '%s' "$value" ;;
  *) return 1 ;;
  esac
}

# Record the layout in /var/lib/pangolin/site-layout, mode 0644, one word
# followed by a newline. Written atomically so a failed write keeps the
# previous value instead of truncating the marker. The marker never holds
# credentials.
write_site_conversion_marker() {
  local value="${1:-}" marker tmp
  case "$value" in
  template | single) ;;
  *)
    echo "write_site_conversion_marker: expected template or single" >&2
    return 1
    ;;
  esac
  marker="$(p /var/lib/pangolin/site-layout)"
  install -d -m 0755 "$(dirname "$marker")" || return 1
  tmp="$(mktemp "${marker}.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    echo "Failed to write $marker" >&2
    return 1
  fi
  return 0
}

# Succeed when the per-slug template layout exists on disk: the marker records
# template, the systemd template unit is installed, or any OpenRC per-slug
# init script is present. Pure file inspection under PANGOLIN_ROOT; it never
# queries or changes a service manager.
_site_template_layout_present() {
  local path
  [[ "$(_site_conversion_marker || true)" == template ]] && return 0
  [[ -e "$(p /etc/systemd/system/pangolin-site@.service)" ]] && return 0
  for path in "$(p /etc/init.d)"/pangolin-site-*; do
    # An unexpanded glob keeps the literal `*`; slugs cannot contain one.
    [[ "$path" != *'*'* && ( -e "$path" || -L "$path" ) ]] && return 0
  done
  return 1
}

# Succeed when legacy single-instance service artifacts exist: the systemd
# unit or its wants symlink, or the OpenRC init script or its default-runlevel
# entry. The legacy site.json and env file are deliberately excluded: a
# converted host keeps site.json for one release to protect rollback, so it
# must still read as `template`, not `mixed`.
_site_legacy_service_present() {
  local path
  for path in "$(p /etc/systemd/system/pangolin-site.service)" \
    "$(p /etc/systemd/system/multi-user.target.wants/pangolin-site.service)" \
    "$(p /etc/init.d/pangolin-site)" \
    "$(p /etc/runlevels/default/pangolin-site)"; do
    if [[ -e "$path" || -L "$path" ]]; then
      return 0
    fi
  done
  return 1
}

# Print the site layout state without touching any service:
#   template — converted; the per-slug path is authoritative
#   mixed    — legacy and template artifacts coexist; a conversion must repair
#   single   — legacy-only install, or a host with nothing installed yet
site_conversion_state() {
  local template_present=0 legacy_present=0
  if _site_template_layout_present; then
    template_present=1
  fi
  if _site_legacy_service_present; then
    legacy_present=1
  fi
  if ((template_present && legacy_present)); then
    echo mixed
  elif ((template_present)); then
    echo template
  else
    echo single
  fi
}

# Print 1 for the accepted true spellings (1, true, yes) and 0 otherwise, so
# every multi-site boolean is normalized before it reaches the payload.
_normalize_bool() {
  case "${1:-}" in
  1 | true | yes) printf '1' ;;
  *) printf '0' ;;
  esac
}

# Succeed when the operator requested the multi-site layout: a MULTI_SITE
# entry in the flags file given as argument 1 wins when present; otherwise the
# MULTI_SITE or var_multi_sites environment variables apply. Every spelling is
# normalized through _normalize_bool, so true and yes mean 1. The entry point
# owns these flags; the payload only reads them.
multi_site_requested() {
  local flags="${1:-}" value
  if [[ -n "$flags" && -f "$flags" ]]; then
    value="$(_env_value "$flags" MULTI_SITE || true)"
    if [[ -n "$value" ]]; then
      [[ "$(_normalize_bool "$value")" == 1 ]] && return 0
      return 1
    fi
  fi
  [[ "$(_normalize_bool "${MULTI_SITE:-}")" == 1 ]] && return 0
  [[ "$(_normalize_bool "${var_multi_sites:-}")" == 1 ]] && return 0
  return 1
}

# Ensure the per-slug site configuration directory exists with mode 0700.
# install -d only applies -m when it creates the directory, so force the
# mode afterwards: a pre-existing wider directory must never keep shared
# credentials readable by others.
ensure_site_config_dir() {
  local dir
  dir="$(site_config_dir)"
  install -d -m 0700 "$dir" || return 1
  chmod 0700 "$dir" || return 1
}

# Reconcile one installed site config with the SSH-owner policy. Exactly one
# connector may run the host's embedded SSH daemon: the owner slug must not
# declare disableSsh, and every other slug — plus every slug when the owner
# is none or empty — must declare "disableSsh":true as the final key, the
# only position the addon's config writers use. Configs whose content is not
# the addon one-line JSON object are never rewritten: the caller must fail
# and ask for a reconfigure instead. A missing config is skipped; creating
# it is the caller's job.
reconcile_site_ssh_owner() {
  local slug="${1:-}" owner="${2:-}"
  local cfg content new keeps=0
  cfg="$(site_config_path "$slug")" || return 1
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  if ! content="$(cat "$cfg" 2>/dev/null)"; then
    echo "reconcile_site_ssh_owner: cannot read $cfg; rerun with var_reconfigure=1." >&2
    return 1
  fi
  if [[ "$content" == *$'\n'* ]]; then
    echo "reconcile_site_ssh_owner: $cfg is not in the addon one-line JSON format; rerun with var_reconfigure=1 to regenerate the configuration." >&2
    return 1
  fi
  case "$content" in
  '{'*'}') ;;
  *)
    echo "reconcile_site_ssh_owner: $cfg is not in the addon one-line JSON format; rerun with var_reconfigure=1 to regenerate the configuration." >&2
    return 1
    ;;
  esac
  if [[ -n "$owner" && "$owner" != none && "$owner" == "$slug" ]]; then
    keeps=1
  fi
  new="$content"
  if ((keeps == 1)); then
    case "$content" in
    *',"disableSsh":true}') new="${content%,\"disableSsh\":true\}}" ;;
    *',"disableSsh":false}') new="${content%,\"disableSsh\":false\}}" ;;
    *'"disableSsh"'*)
      echo "reconcile_site_ssh_owner: $cfg has a disableSsh key outside the addon one-line format; rerun with var_reconfigure=1 to regenerate the configuration." >&2
      return 1
      ;;
    esac
  else
    case "$content" in
    *',"disableSsh":true}') ;;
    *',"disableSsh":false}') new="${content%,\"disableSsh\":false\}},\"disableSsh\":true}" ;;
    *'"disableSsh"'*)
      echo "reconcile_site_ssh_owner: $cfg has a disableSsh key outside the addon one-line format; rerun with var_reconfigure=1 to regenerate the configuration." >&2
      return 1
      ;;
    *) new="${content%\}},\"disableSsh\":true}" ;;
    esac
  fi
  if [[ "$new" != "$content" ]]; then
    write_private_file "$cfg" "$new" || return 1
  fi
  return 0
}

# Apply the SSH-owner policy to every listed slug with an installed config.
# Flags written by the pre-multi-site entry carry no SSH_OWNER key, so the
# policy is skipped there and legacy conversions keep their configs
# byte-for-byte.
_enforce_site_ssh_policy() {
  local flags="${1:-}"
  shift
  local slug owner
  if [[ -z "$flags" || ! -f "$flags" ]] || ! grep -q '^SSH_OWNER=' "$flags" 2>/dev/null; then
    return 0
  fi
  owner="$(_env_value "$flags" SSH_OWNER || true)"
  for slug in "$@"; do
    if [[ -f "$(site_config_path "$slug" 2>/dev/null || true)" ]]; then
      if ! reconcile_site_ssh_owner "$slug" "$owner"; then
        return 1
      fi
    fi
  done
}

# Convert a legacy single-site install to the per-slug template layout. One-way
# and idempotent: the marker (or an installed template unit) makes every later
# run use the template path, even with only `default`, and reverting requires
# an explicit reinstall.
#
# Arguments: the backend, the answers flags file (may be empty or absent), and
# the requested slugs (default: just `default`). The function converts when
# several slugs are requested, when a non-default slug is requested, when
# multi_site_requested says so, and always when the state is `mixed`, so an
# interrupted conversion converges. With only `default` on an unconverted host
# it returns quietly and the caller keeps the legacy single-site path. In the
# already-converted `template` state the import and legacy steps are skipped,
# but every requested slug — the default included — is reconciled with
# restart-if-was-active semantics, so a replaced sites/default.json takes
# effect and a rerun after a failed extra slug converges instead of silently
# succeeding. When the entry supplied an SSH_OWNER flag, the owner policy is
# reconciled for every installed config before any instance starts.
#
# Safety rules, asserted by the test suite:
#   - the same site credentials are never active twice: the legacy service is
#     stopped with stop_service *before* pangolin-site@default starts, the
#     legacy unit files are retired only after @default verifies, and the
#     rollback never starts the restored legacy service while an unverified
#     @default instance is still reported active;
#   - a failing @default removes its own instance, restores the backup, starts
#     no extra slug, and restarts the legacy service only once @default is
#     confirmed not active;
#   - a failing extra slug is stopped, disabled, and removed alone, leaving
#     every verified instance running;
#   - the marker is written only after @default verified.
#
# /etc/pangolin/site.json is copied, never deleted: it stays one release for
# rollback. Later runs read sites/default.json, so edits to the legacy file
# after a conversion are ignored; a follow-up release removes the leftover.
convert_site_layout() {
  local backend="${1:-}"
  if (($# > 0)); then shift; fi
  local flags="${1:-}"
  if (($# > 0)); then shift; fi
  local -a slugs=("$@")
  local slug path state rc=0 converted=0
  local default_cfg legacy_json backup_dir="" legacy_was_active=0 default_was_active=0
  local -a legacy_paths=()
  ((${#slugs[@]} > 0)) || slugs=(default)

  case "$backend" in
  systemd | openrc) ;;
  *)
    echo "convert_site_layout: expected systemd or openrc" >&2
    return 1
    ;;
  esac
  for slug in "${slugs[@]}"; do
    if [[ "$slug" == host ]] || ! [[ "$slug" =~ ^[a-z]([a-z0-9-]{0,8}[a-z0-9])?$ ]]; then
      echo "convert_site_layout: invalid or reserved site slug: ${slug//[[:cntrl:]]/}" >&2
      return 1
    fi
  done

  state="$(site_conversion_state)"
  local -a extra_slugs=()
  for slug in "${slugs[@]}"; do
    [[ "$slug" == default ]] || extra_slugs+=("$slug")
  done

  if [[ "$state" != template ]]; then
    if [[ "$state" == single ]] && ((${#extra_slugs[@]} == 0)) &&
      ! multi_site_requested "$flags"; then
      # Conversion trigger: several slugs, any non-default slug, or an
      # explicit multi-site request. A `mixed` layout always repairs.
      return 0
    fi

    # Step 1: import the default configuration. An existing per-slug file is
    # authoritative, so a rerun or a mixed repair never re-imports.
    default_cfg="$(site_config_path default)"
    legacy_json="$(p /etc/pangolin/site.json)"
    if [[ ! -e "$default_cfg" ]]; then
      ensure_site_config_dir || return 1
      if [[ -f "$legacy_json" ]]; then
        # Byte-for-byte copy: credentials, provisioning key, and native state
        # carry over untouched, and the legacy file stays in place.
        install -m 0600 "$legacy_json" "$default_cfg" || return 1
      elif [[ -n "$LEGACY_NEWT_ID" && -n "$LEGACY_NEWT_SECRET" && -n "$LEGACY_ENDPOINT" ]]; then
        write_private_file "$default_cfg" \
          "$(site_config_static "$LEGACY_ENDPOINT" "$LEGACY_NEWT_ID" "$LEGACY_NEWT_SECRET")" ||
          return 1
      else
        echo "convert_site_layout: no site configuration to convert; provide $legacy_json or Newt credentials first." >&2
        return 1
      fi
    fi

    # Step 1b: apply the SSH-owner policy to every imported or supplied
    # config, including a default that was not explicitly requested. An
    # unreconciled config must never reach a running instance, so a refusal
    # aborts here, before any backup, stop, or start.
    if ! _enforce_site_ssh_policy "$flags" default "${slugs[@]}"; then
      echo "convert_site_layout: the SSH-owner policy could not be applied; no instances were changed." >&2
      return 1
    fi

    # Step 2: record what the legacy cleanup may remove once the conversion
    # verifies, then back up the legacy unit, env, and wrapper so a failed
    # default can restore the original files. A backup failure aborts before
    # anything is stopped.
    _record_legacy_paths
    for path in "$(p /etc/systemd/system/pangolin-site.service)" \
      "$(p /etc/systemd/system/multi-user.target.wants/pangolin-site.service)" \
      "$(p /etc/init.d/pangolin-site)" \
      "$(p /etc/runlevels/default/pangolin-site)" \
      "$(p /usr/local/bin/pangolin-site-start)" \
      "$(p /etc/pangolin/pangolin-site.env)"; do
      if [[ -e "$path" || -L "$path" ]]; then
        legacy_paths+=("$path")
      fi
    done
    if ((${#legacy_paths[@]} > 0)); then
      if ! backup_dir="$(backup_existing "${legacy_paths[@]}")"; then
        echo "convert_site_layout: failed to back up the legacy site files; refusing to convert." >&2
        return 1
      fi
    fi

    # Step 3: stop the legacy service before @default starts, never after.
    if _site_legacy_service_present; then
      case "$backend" in
      systemd)
        systemctl is-active --quiet pangolin-site >/dev/null 2>&1 && legacy_was_active=1
        ;;
      openrc)
        rc-service pangolin-site status >/dev/null 2>&1 && legacy_was_active=1
        ;;
      esac
    fi
    if [[ "$legacy_was_active" == 1 ]]; then
      echo "Converting the single-site service to per-slug instances; the site tunnel restarts briefly."
      if ! stop_service "$backend" pangolin-site; then
        echo "convert_site_layout: failed to stop the legacy pangolin-site service; the conversion did not run." >&2
        return 1
      fi
    fi

    # Step 4: install and verify @default. An already-running instance (a mixed
    # repair) is restarted so the authoritative config applies.
    case "$backend" in
    systemd)
      site_instance_was_active default >/dev/null 2>&1 && default_was_active=1
      ;;
    openrc)
      site_instance_was_active_openrc default >/dev/null 2>&1 && default_was_active=1
      ;;
    esac
    local install_default_ok=1
    case "$backend" in
    systemd) install_site_systemd_slug default "$default_cfg" "$default_was_active" || install_default_ok=0 ;;
    openrc) install_site_openrc_slug default "$default_cfg" "$default_was_active" || install_default_ok=0 ;;
    esac
    if ((install_default_ok == 0)); then
      # Rollback: the unverified instance must not stay enabled beside the
      # legacy unit, so remove it, restore the original files, and bring the
      # legacy service back when it had been running. The legacy start waits
      # for proof the instance is gone: a verification timeout can leave the
      # process alive, and starting the legacy unit then would run the same
      # site credentials twice.
      local instance_label default_still_active=0
      case "$backend" in
      systemd) instance_label="$(site_systemd_instance default)" ;;
      openrc) instance_label="$(site_openrc_instance default)" ;;
      esac
      if ! uninstall_site_slug "$backend" default; then
        echo "convert_site_layout: failed to remove the unverified $instance_label instance." >&2
      fi
      case "$backend" in
      systemd) site_instance_was_active default >/dev/null 2>&1 && default_still_active=1 ;;
      openrc) site_instance_was_active_openrc default >/dev/null 2>&1 && default_still_active=1 ;;
      esac
      if [[ -n "$backup_dir" ]] && ! restore_backup "$backup_dir"; then
        echo "convert_site_layout: failed to restore the legacy files from $backup_dir; the legacy service needs operator attention." >&2
        return 1
      fi
      if [[ "$backend" == systemd && -z "$PANGOLIN_ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
      fi
      if [[ "$legacy_was_active" == 1 ]]; then
        if ((default_still_active == 1)); then
          if [[ "$backend" == systemd ]]; then
            echo "convert_site_layout: $instance_label is still active, so pangolin-site was restored but NOT started; the same site credentials must never run twice. Stop it first: systemctl stop $instance_label, then run: systemctl start pangolin-site" >&2
          else
            echo "convert_site_layout: $instance_label is still active, so pangolin-site was restored but NOT started; the same site credentials must never run twice. Stop it first: rc-service $instance_label stop, then run: rc-service pangolin-site start" >&2
          fi
          return 1
        fi
        echo "The $instance_label instance failed verification; restarting the legacy service." >&2
        case "$backend" in
        systemd)
          systemctl start pangolin-site ||
            echo "convert_site_layout: restored the legacy unit but failed to start it; it needs operator attention." >&2
          ;;
        openrc)
          rc-service pangolin-site start ||
            echo "convert_site_layout: restored the legacy service but failed to start it; it needs operator attention." >&2
          ;;
        esac
      fi
      return 1
    fi
    converted=1

    # Step 5: @default verified. Retire the legacy service plumbing, run the
    # recorded legacy cleanup (legacy-format env only, content-checked wrapper,
    # updater compatibility policy), then record the marker. A failed retire or
    # cleanup keeps the layout `mixed` for the next run to repair.
    case "$backend" in
    systemd)
      if ! retire_legacy_single_site_systemd; then
        echo "convert_site_layout: pangolin-site@default is verified, but retiring the legacy service failed; rerun the conversion to finish." >&2
        rc=1
      fi
      ;;
    openrc)
      if ! retire_legacy_single_site_openrc; then
        echo "convert_site_layout: pangolin-site@default is verified, but retiring the legacy service failed; rerun the conversion to finish." >&2
        rc=1
      fi
      ;;
    esac
    if ! cleanup_legacy_addon site; then
      echo "convert_site_layout: the site instances are verified, but legacy site cleanup failed." >&2
      rc=1
    fi
    if ! write_site_conversion_marker template; then
      echo "convert_site_layout: failed to write the conversion marker; later runs may not detect the template layout." >&2
      rc=1
    fi
  fi

  # Step 6: reconcile the requested slugs. This runs on the template path
  # too: a rerun after a failed extra slug must converge, not silently
  # succeed while the slug is missing. On the template path the default slug
  # is included: a replaced sites/default.json must reach the running
  # @default instance through the restart-if-was-active path. A failure
  # removes only that instance and leaves every verified instance running;
  # the run still fails.
  local -a reconcile_slugs=()
  if [[ "$state" == template ]]; then
    # Reconcile must not start an instance whose SSH-owner state is unknown:
    # apply the policy to every installed config first.
    if ! _enforce_site_ssh_policy "$flags" "${slugs[@]}"; then
      echo "convert_site_layout: the SSH-owner policy could not be applied; no instances were changed." >&2
      return 1
    fi
    reconcile_slugs=("${slugs[@]}")
  else
    reconcile_slugs=("${extra_slugs[@]}")
  fi
  for slug in "${reconcile_slugs[@]}"; do
    local slug_cfg slug_was_active=0 slug_ok=1
    slug_cfg="$(site_config_path "$slug")"
    if [[ ! -f "$slug_cfg" ]]; then
      echo "convert_site_layout: missing $slug_cfg for the $slug instance; the config must be provided before installing." >&2
      rc=1
      continue
    fi
    case "$backend" in
    systemd) site_instance_was_active "$slug" >/dev/null 2>&1 && slug_was_active=1 ;;
    openrc) site_instance_was_active_openrc "$slug" >/dev/null 2>&1 && slug_was_active=1 ;;
    esac
    case "$backend" in
    systemd) install_site_systemd_slug "$slug" "$slug_cfg" "$slug_was_active" || slug_ok=0 ;;
    openrc) install_site_openrc_slug "$slug" "$slug_cfg" "$slug_was_active" || slug_ok=0 ;;
    esac
    if ((slug_ok == 0)); then
      if ! uninstall_site_slug "$backend" "$slug"; then
        echo "convert_site_layout: failed to remove the unverified $slug instance." >&2
      fi
      echo "convert_site_layout: the $slug instance failed verification and was removed; the other instances keep running." >&2
      rc=1
    fi
  done

  if ((rc == 0 && converted == 1)); then
    echo "Converted the single-site install to per-slug site services."
  fi
  return "$rc"
}

# Push the payload and every regular file in the answers directory into
# /root/.pangolin-addon with explicit modes. Older versions of `pct push` have
# no --perms option, so a failed push is retried without it and the mode is
# applied with chmod inside the container. File contents never enter argv.
push_payload() {
  local ctid="${1:-}" payload="${2:-}" answers="${3:-}" file base remote subdir sbase
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
  # Multi-site runs add a sites/ subdirectory of per-slug configs. It is a
  # second-level directory, so push the directory itself with a private mode
  # and push each slug config into it with mode 600.
  if [[ -d "$answers/sites" ]]; then
    if ! pct exec "$ctid" -- sh -c \
      'mkdir -p /root/.pangolin-addon/sites && chmod 700 /root/.pangolin-addon/sites'; then
      return 1
    fi
    for subdir in "$answers/sites"/*; do
      [[ -f "$subdir" ]] || continue
      sbase="$(basename "$subdir")"
      if ! pct push "$ctid" "$subdir" "$remote/sites/$sbase" --perms 600; then
        pct push "$ctid" "$subdir" "$remote/sites/$sbase" || return 1
        pct exec "$ctid" -- chmod 600 "$remote/sites/$sbase" || return 1
      fi
    done
  fi
  for file in "$answers"/*; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    [[ "$base" == payload.sh ]] && continue
    [[ "$base" == sites ]] && continue
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
  systemd) install_site_systemd "$config" "$SITE_INSTALL_WAS_ACTIVE" || return 1 ;;
  openrc) install_site_openrc "$config" "$SITE_INSTALL_WAS_ACTIVE" || return 1 ;;
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
  systemd) install_client_systemd "$cid" "$csecret" "$cendpoint" "$CLIENT_INSTALL_WAS_ACTIVE" || return 1 ;;
  openrc) install_client_openrc "$cid" "$csecret" "$cendpoint" "$CLIENT_INSTALL_WAS_ACTIVE" || return 1 ;;
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

# Disable a service that a failed fresh install enabled. A fresh install has no
# previous files to restore, so leaving it enabled would restart-loop after
# reboot. Never touches a service manager under PANGOLIN_ROOT, so tests stay
# hermetic; explicit helper tests use fake binaries in PATH.
_disable_service() {
  local backend="$1" name="$2"
  [[ -z "$PANGOLIN_ROOT" ]] || return 0
  case "$backend" in
  systemd)
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl disable "$name" || {
      echo "Failed to disable the failed $name service" >&2
      return 1
    }
    ;;
  openrc)
    command -v rc-update >/dev/null 2>&1 || return 0
    rc-update del "$name" default || {
      echo "Failed to remove the failed $name service from the default runlevel" >&2
      return 1
    }
    ;;
  *) return 1 ;;
  esac
}

# Restore a pre-install backup and restart the previous service when it was
# active. Called only after a failed replacement. A fresh install has no
# backup, so the newly enabled service is disabled instead of left enabled.
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
  if [[ -z "$backup_dir" ]]; then
    _disable_service "$backend" "$name" || rc=1
    echo "The failed $name install had no previous files; disabled the new service." >&2
    return "$rc"
  fi
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

# Succeed when the slug's site instance is active and its configuration
# holds real credentials rather than a pending provisioning key. Read-only:
# it queries the service manager and the config file only.
_site_slug_verified() {
  local backend="$1" slug="${2:-}" cfg
  cfg="$(site_config_path "$slug" 2>/dev/null)" || return 1
  [[ -f "$cfg" ]] || return 1
  case "$backend" in
  systemd) site_instance_was_active "$slug" >/dev/null 2>&1 || return 1 ;;
  openrc) site_instance_was_active_openrc "$slug" >/dev/null 2>&1 || return 1 ;;
  *) return 1 ;;
  esac
  if grep -q '"provisioningKey"[[:space:]]*:' "$cfg" 2>/dev/null; then
    return 1
  fi
  site_config_has_credentials "$cfg"
}

# Install every requested slug from the answers directory in one pass. The
# answers dir holds sites/<slug>.json; each supplied config is installed
# authoritatively (mode 0600) so a rerun with new credentials replaces the
# per-slug file before conversion. convert_site_layout then installs and
# verifies the default and each extra slug independently, removing any
# instance that fails while leaving the verified ones running.
_install_site_multi() {
  local backend="$1" answers="$2" flags="$3" verified_file="$4" rc=0
  local raw slug cfg src installed=0 verified
  local -a slugs=()
  raw="$(_env_value "$flags" SITE_SLUGS || true)"
  read -r -a slugs <<<"$raw"
  if ((${#slugs[@]} == 0)); then
    slugs=(default)
  fi
  # SSH_OWNER is parsed for the log contract; the entry has already baked it
  # into each slug's config as the disableSsh key. Echoing the owner label is
  # safe: it is a site slug, never a credential.
  local ssh_owner
  ssh_owner="$(_env_value "$flags" SSH_OWNER || true)"
  if [[ -n "$ssh_owner" && "$ssh_owner" =~ ^[a-z]([a-z0-9-]{0,8}[a-z0-9])?$|^(default|none)$ ]]; then
    echo "Site SSH owner: $ssh_owner"
  fi
  if [[ -d "$answers/sites" ]]; then
    if ! ensure_site_config_dir; then
      echo "Failed to create $(site_config_dir)." >&2
      return 1
    fi
    for slug in "${slugs[@]}"; do
      if ! cfg="$(site_config_path "$slug")"; then
        rc=1
        continue
      fi
      src="$answers/sites/$slug.json"
      [[ -f "$src" ]] || continue
      if ! install -m 0600 "$src" "$cfg"; then
        echo "Failed to install $cfg." >&2
        rc=1
      fi
    done
  fi
  if ((rc == 0)) && ! convert_site_layout "$backend" "$flags" "${slugs[@]}"; then
    rc=1
  fi
  _record_verified "$verified_file" "backend:$backend" || rc=1
  for slug in "${slugs[@]}"; do
    verified=0
    if _site_slug_verified "$backend" "$slug"; then
      verified=1
      installed=$((installed + 1))
      _record_verified "$verified_file" "site:$slug" || rc=1
      if [[ "$slug" == default ]]; then
        _record_verified "$verified_file" site || rc=1
      fi
    fi
    if ((verified == 0)); then
      echo "The pangolin-site instance for $slug did not verify." >&2
      rc=1
    fi
  done
  if ((installed > 0)); then
    cleanup_legacy_newt || {
      echo "The site instances are verified, but legacy Newt cleanup failed." >&2
      rc=1
    }
  fi
  return "$rc"
}

# Install the selected components from a private answers directory. Components
# are independent: a verified component stays installed when the other fails,
# and the failed component is stopped without touching the earlier one.
payload_main() {
  local answers="${1:-}" flags verified_file backend site client reconfigure rc=0 site_verified=0
  local target multi_site=0
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
  # The entry records its selected target for diagnostics; the payload only
  # reads it, and never echoes unvalidated flag content into a log line.
  target="$(_env_value "$flags" TARGET || true)"
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
  if [[ "$site" == 1 ]] && multi_site_requested "$flags"; then
    multi_site=1
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
    if [[ "$multi_site" == 1 ]]; then
      # Multi-slug path: one convert_site_layout call installs every
      # requested slug. Instances that fail are removed there while the
      # verified ones keep running; this run still ends non-zero.
      _install_site_multi "$backend" "$answers" "$flags" "$verified_file" || rc=1
    elif ! _backup_install_paths "$backend" site; then
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

# Run main when executed as a file, piped through stdin, or read from a
# process-substitution descriptor. An empty BASH_SOURCE[0] (bash -c or stdin)
# must not fail under set -u.
if [[ "${BASH_SOURCE[0]:-}" == "" ||
  "${BASH_SOURCE[0]}" == "$0" ||
  "${BASH_SOURCE[0]}" == /dev/fd/* ]]; then
  payload_main "$@"
fi
