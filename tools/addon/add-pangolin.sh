#!/usr/bin/env bash

# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Source: https://docs.pangolin.net/manage/clients/install-client |
#         https://docs.pangolin.net/manage/sites/install-site | Github: https://github.com/fosrl/cli
#
# Pangolin addon entry point. This file validates operator input, fetches the
# shared install payload, and builds the private answers directory that the
# payload consumes. The install orchestration lives in the payload.
#
# Unattended:
#   var_mode=site|client|both          (interactive menu when unset)
#   var_targets="host 101 102"         (space- or comma-separated; var_target
#                                       still accepts exactly one target)
#   Site/both: var_pangolin_endpoint=... var_site_id=... var_site_secret=...
#              or var_site_provisioning_key=... var_site_name=...
#              Per target: var_site_id_<host|CTID>=... and the same suffix on
#              var_site_secret, var_site_provisioning_key, and var_site_name.
#   Client/both: var_client_id=... var_client_secret=...
#              Per target: var_client_id_<host|CTID>, var_client_secret_<host|CTID>.
#   The unsuffixed credential variables are used only when exactly one target
#   is selected.
#
# Mode, endpoint, site native toggles, and var_reconfigure are shared by every
# target. Each target gets its own private answers directory and install run.

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
PANGOLIN_PAYLOAD_URL="${PANGOLIN_PAYLOAD_URL:-$REPO_RAW/tools/addon/lib/pangolin-payload.sh}"
PANGOLIN_TEST="${PANGOLIN_TEST:-0}"
# Read by the community-scripts core message and header helpers.
APP="${APP:-Pangolin}"
APP_TYPE="${APP_TYPE:-addon}"
# Components the payload verified in this run; used for LXC tags and next steps.
VERIFIED_SITE=0
VERIFIED_CLIENT=0
# Targets selected for this run, in selection order.
TARGETS=()
# Per-target credentials resolved before the install loop.
TARGET_SITE_ID=()
TARGET_SITE_SECRET=()
TARGET_SITE_PROVISIONING_KEY=()
TARGET_SITE_NAME=()
TARGET_CLIENT_ID=()
TARGET_CLIENT_SECRET=()
# Effective reconfigure flag per target. The shared var_reconfigure seeds it.
TARGET_RECONFIGURE=()
# Run results, parallel to TARGETS, for the final summary.
TARGET_STATUS=()
# Every private answers directory and every LXC that received a copy.
TARGET_ANSWERS=()
REMOTE_TARGETS=()
# Private run directory that holds the shared payload and the answers dirs.
WORK_DIR=""

# Load the payload at source time when a local checkout is supplied. Tests use
# this path so the entry helpers can be exercised without network access or a
# Proxmox host. Otherwise main() fetches the payload before it runs.
if [[ -n "${PANGOLIN_PAYLOAD:-}" && -r "$PANGOLIN_PAYLOAD" ]]; then
  # shellcheck disable=SC1090
  source "$PANGOLIN_PAYLOAD"
fi

# Succeed when a Linux interface name is 1-15 characters, starts with a letter,
# and uses only letters, digits, underscore, dash, or dot.
validate_interface_name() {
  local name="${1:-}"
  ((${#name} >= 1 && ${#name} <= 15)) || return 1
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]]
}

# Succeed when a native mode flag is exactly 0 or 1.
validate_native_flag() {
  local flag="${1:-}"
  [[ "$flag" == 0 || "$flag" == 1 ]]
}

# Succeed when the four optional site native arguments are valid. Interface
# names only matter for an enabled mode.
_validate_native_args() {
  local native="${1-0}" native_main="${2-0}"
  local interface="${3-pangolin}" interface_main="${4-pangolin}"
  local rule="1-15 characters, starting with a letter, using letters, digits, _, -, or ."
  validate_native_flag "$native" || {
    echo "Invalid native flag: $native (expected 0 or 1)" >&2
    return 1
  }
  validate_native_flag "$native_main" || {
    echo "Invalid nativeMain flag: $native_main (expected 0 or 1)" >&2
    return 1
  }
  if [[ "$native" == 1 ]] && ! validate_interface_name "$interface"; then
    echo "Invalid native interface name: $interface (expected $rule)" >&2
    return 1
  fi
  if [[ "$native_main" == 1 ]] && ! validate_interface_name "$interface_main"; then
    echo "Invalid nativeMain interface name: $interface_main (expected $rule)" >&2
    return 1
  fi
}

# Succeed when the URL is an http(s) endpoint with a non-empty host and no
# whitespace or control characters.
validate_endpoint() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/?#[:space:]]+ ]] || return 1
  [[ "$url" != *[[:space:][:cntrl:]]* ]] || return 1
  return 0
}

# Succeed when the site name is 1-63 characters with no control characters.
validate_site_name() {
  local name="${1:-}"
  ((${#name} >= 1 && ${#name} <= 63)) || return 1
  [[ "$name" != *[[:cntrl:]]* ]] || return 1
  return 0
}

# Succeed when a dotted version is at least a minimum dotted version.
_os_version_ge() {
  local have="$1" need="$2" i a b max=0
  local -a h n
  IFS='.' read -r -a h <<<"$have"
  IFS='.' read -r -a n <<<"$need"
  max=${#h[@]}
  ((${#n[@]} > max)) && max=${#n[@]}
  for ((i = 0; i < max; i++)); do
    a="${h[i]:-0}"
    b="${n[i]:-0}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    a=$((10#$a))
    b=$((10#$b))
    if ((a > b)); then return 0; fi
    if ((a < b)); then return 1; fi
  done
  return 0
}

# Succeed only for the supported distribution floors: Debian 12+, Ubuntu
# 22.04+, and Alpine 3.20+. Unknown distributions are not supported.
os_supported() {
  local id="${1:-}" version="${2:-}" minimum
  case "$id" in
  debian) minimum="12" ;;
  ubuntu) minimum="22.04" ;;
  alpine) minimum="3.20" ;;
  *) return 1 ;;
  esac
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  _os_version_ge "$version" "$minimum"
}

# Print /etc/os-release content from the host or an LXC container.
_target_os_release() {
  local target="$1"
  if [[ "$target" == host ]]; then
    cat /etc/os-release 2>/dev/null
  else
    pct exec "$target" -- cat /etc/os-release 2>/dev/null
  fi
}

# Print one unquoted field from /etc/os-release content.
_release_field() {
  local release="$1" key="$2" line
  line="$(printf '%s\n' "$release" | sed -n "s/^$key=//p" | head -n 1)"
  [[ -n "$line" ]] || return 1
  line="${line%\"}"
  line="${line#\"}"
  printf '%s' "$line"
}

# Refuse an unsupported target before the payload is fetched or the target is
# changed beyond starting a stopped container.
_validate_target_os() {
  local target="$1" release id version
  if ! release="$(_target_os_release "$target")"; then
    echo "Cannot read /etc/os-release on $target." >&2
    return 1
  fi
  id="$(_release_field "$release" ID || true)"
  version="$(_release_field "$release" VERSION_ID || true)"
  if [[ -z "$id" || -z "$version" ]]; then
    echo "Cannot determine the operating system of $target from /etc/os-release." >&2
    return 1
  fi
  if ! os_supported "$id" "$version"; then
    echo "Unsupported target OS: $id $version. Supported: Debian 12+, Ubuntu 22.04+, Alpine 3.20+." >&2
    return 1
  fi
  echo "Target OS supported: $id $version."
}

# Print the enabled components for a mode as "SITE CLIENT" (each 0 or 1).
components_from_mode() {
  case "${1:-}" in
  site) printf '1 0\n' ;;
  client) printf '0 1\n' ;;
  both) printf '1 1\n' ;;
  *) return 1 ;;
  esac
}

# Succeed when the selected components need /dev/net/tun and root or
# CAP_NET_ADMIN. Client mode needs TUN; site mode only with a native interface.
tun_required() {
  local client="${1-0}" native="${2-0}" native_main="${3-0}"
  [[ "$client" == 1 || "$native" == 1 || "$native_main" == 1 ]]
}

# Put the shared payload at dest, either by copying the local override or by
# downloading the latest copy from REPO_RAW. Always leaves a mode 0600 file.
fetch_payload() {
  local dest="$1"
  if [[ -n "${PANGOLIN_PAYLOAD:-}" && -r "$PANGOLIN_PAYLOAD" ]]; then
    install -m 0600 "$PANGOLIN_PAYLOAD" "$dest" || return 1
  else
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120 \
      "$PANGOLIN_PAYLOAD_URL" -o "$dest" || return 1
    chmod 0600 "$dest" || return 1
  fi
}

# Write <dir>/site.json for a provisioning key or for static credentials. The
# optional trailing native arguments are "native nativeMain interface
# interfaceMain"; a dash means "not supplied" only for the credential fields.
# The key wins when both credential forms are present.
build_site_answers() {
  local dir="$1" endpoint="$2" key="$3" name="$4" id="$5" secret="$6"
  local native="${7-0}" native_main="${8-0}" interface="${9-pangolin}"
  local interface_main="${10-pangolin}" config
  validate_endpoint "$endpoint" || {
    echo "Invalid Pangolin endpoint: $endpoint" >&2
    return 1
  }
  _validate_native_args "$native" "$native_main" "$interface" "$interface_main" || return 1
  if [[ "$key" != "-" && -n "$key" ]]; then
    [[ "$name" == "-" ]] && name=""
    config="$(site_config_provisioning "$endpoint" "$key" "$name" \
      "$native" "$native_main" "$interface" "$interface_main")"
  else
    if [[ "$id" == "-" || -z "$id" || "$secret" == "-" || -z "$secret" ]]; then
      echo "Site answers need a provisioning key or an id and secret" >&2
      return 1
    fi
    config="$(site_config_static "$endpoint" "$id" "$secret" \
      "$native" "$native_main" "$interface" "$interface_main")"
  fi
  install -d -m 0700 "$dir" || return 1
  write_private_file "$dir/site.json" "$config"
}

# Write <dir>/client.env with the machine client credentials and mode 0600.
build_client_answers() {
  local dir="$1" endpoint="$2" id="$3" secret="$4" content
  validate_endpoint "$endpoint" || {
    echo "Invalid Pangolin endpoint: $endpoint" >&2
    return 1
  }
  if [[ -z "$id" || -z "$secret" ]]; then
    echo "Client answers need an id and secret" >&2
    return 1
  fi
  content="$(printf 'PANGOLIN_CLIENT_ID=%s\nPANGOLIN_CLIENT_SECRET=%s\nPANGOLIN_ENDPOINT=%s' \
    "$(_shell_single_quote "$id")" "$(_shell_single_quote "$secret")" \
    "$(_shell_single_quote "$endpoint")")"
  install -d -m 0700 "$dir" || return 1
  write_private_file "$dir/client.env" "$content"
}

CS_CORE_RAW="${CS_CORE_RAW:-https://raw.githubusercontent.com/community-scripts/core/main}"

# The entry fetches the core files and the payload with curl. Install it from
# the host's package manager when a minimal Proxmox image lacks it.
_ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates ||
      return 1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates || return 1
  else
    return 1
  fi
  command -v curl >/dev/null 2>&1
}

# Fetch and source one community-scripts core file. Failure is not fatal: the
# local message and Proxmox host fallbacks below keep the addon runnable.
_core_fetch() {
  local url="$1" content
  content="$(curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 "$url")" ||
    return 1
  [[ -n "$content" ]] || return 1
  # shellcheck disable=SC1091
  source /dev/stdin <<<"$content"
}

# Define the small set of core helpers the entry uses when the core files are
# unavailable. Core definitions, when present, always win.
_install_fallbacks() {
  if ! declare -F msg_info >/dev/null 2>&1; then
    msg_info() { printf ' [INFO] %s\n' "$*"; }
  fi
  if ! declare -F msg_ok >/dev/null 2>&1; then
    msg_ok() { printf ' [OK] %s\n' "$*"; }
  fi
  if ! declare -F msg_warn >/dev/null 2>&1; then
    msg_warn() { printf ' [WARN] %s\n' "$*" >&2; }
  fi
  if ! declare -F msg_error >/dev/null 2>&1; then
    msg_error() { printf ' [ERROR] %s\n' "$*" >&2; }
  fi
  if ! declare -F header_info >/dev/null 2>&1; then
    header_info() { printf '\nPangolin Addon (CLI)\n\n'; }
  fi
  if ! declare -F require_pve_host >/dev/null 2>&1; then
    require_pve_host() {
      if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve ]]; then
        return 0
      fi
      msg_error "This script must be run on the Proxmox VE host (not inside an LXC container)."
      return 232
    }
  fi
}

_load_core() {
  if ! declare -F msg_info >/dev/null 2>&1; then
    _core_fetch "$CS_CORE_RAW/core/core.func" >/dev/null 2>&1 || true
  fi
  if declare -F load_functions >/dev/null 2>&1; then
    load_functions || true
  fi
  _install_fallbacks
}

# Any var_mode selects non-interactive mode. var_unattended=1 is an alias, but
# still requires an explicit var_mode because there is nothing to prompt with.
_is_noninteractive() {
  [[ -n "${var_mode:-}" || "${var_unattended:-0}" == 1 ]]
}

# Print the mode, prompting only when no var_mode and no unattended alias exist.
_resolve_mode() {
  local mode="${var_mode:-}" choice
  if [[ -n "$mode" ]]; then
    components_from_mode "$mode" >/dev/null || {
      echo "Invalid var_mode: $mode (expected site, client, or both)" >&2
      return 1
    }
    printf '%s\n' "$mode"
    return 0
  fi
  if [[ "${var_unattended:-0}" == 1 ]]; then
    echo "var_mode is required when var_unattended=1" >&2
    return 1
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required for interactive mode" >&2
    return 1
  fi
  choice="$(whiptail --title "Pangolin Addon" --menu "Select components" 15 64 3 \
    site "Site (the Newt replacement)" \
    client "Machine client (VPN)" \
    both "Site and client" 3>&1 1>&2 2>&3)" || return 1
  printf '%s\n' "$choice"
}

# Print one normalized target per line: `host` or a CTID without leading zeros.
# Accepts a space- or comma-separated list. Rejects non-numeric values, CTID 0,
# and duplicates (including leading-zero spellings).
_parse_targets() {
  local raw="${1:-}" token seen=" " ctid
  local -a tokens=()
  raw="${raw//,/ }"
  # Word splitting is intentional: the list is space- or comma-separated.
  # shellcheck disable=SC2206
  tokens=($raw)
  if ((${#tokens[@]} == 0)); then
    echo "No targets selected (expected host or CTIDs)" >&2
    return 1
  fi
  for token in "${tokens[@]}"; do
    case "$token" in
    host) ;;
    *)
      if [[ ! "$token" =~ ^[0-9]+$ ]]; then
        echo "Invalid target: $token (expected host or a CTID)" >&2
        return 1
      fi
      ctid=$((10#$token))
      if ((ctid <= 0)); then
        echo "Invalid target: $token (expected a CTID greater than 0)" >&2
        return 1
      fi
      token="$ctid"
      ;;
    esac
    if [[ "$seen" == *" $token "* ]]; then
      echo "Duplicate target: $token" >&2
      return 1
    fi
    seen="${seen}${token} "
    printf '%s\n' "$token"
  done
}

# Print the whiptail checklist rows: the host first, then every LXC on this
# host. `pct list` output is VMID Status Lock Name; the name may move columns
# when the container is locked, so the last field is used.
_target_choices() {
  printf 'host\tThis Proxmox host\n'
  if command -v pct >/dev/null 2>&1; then
    pct list 2>/dev/null | tail -n +2 |
      awk 'NF >= 2 && $1 ~ /^[0-9]+$/ { printf "%s\tLXC %s (CTID %s)\n", $1, $NF, $1 }'
  fi
}

# Print every selected target, one per line. Uses var_targets first, then the
# single-target var_target, then an interactive checklist.
_resolve_targets() {
  local raw="${var_targets:-}" choice item label
  local -a items=()
  if [[ -z "$raw" ]]; then
    raw="${var_target:-}"
  fi
  if [[ -n "$raw" ]]; then
    _parse_targets "$raw"
    return
  fi
  if _is_noninteractive; then
    echo "var_targets or var_target is required (host or CTIDs)" >&2
    return 1
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required for interactive mode" >&2
    return 1
  fi
  while IFS=$'\t' read -r item label; do
    [[ -n "$item" ]] && items+=("$item" "$label" "OFF")
  done <<<"$(_target_choices)"
  choice="$(whiptail --title "Pangolin Addon" --checklist \
    "Targets (space selects, Enter confirms)" 20 74 12 "${items[@]}" 3>&1 1>&2 2>&3)" ||
    return 1
  if [[ -z "${choice//[[:space:]\"\']/}" ]]; then
    echo "Select at least one target" >&2
    return 1
  fi
  _parse_targets "$(printf '%s' "$choice" | tr -d '"')"
}

# Print the hostname used as the default provisioning site name.
_default_site_name() {
  local target="$1"
  if [[ "$target" == host ]]; then
    hostname 2>/dev/null || printf 'pve\n'
  else
    pct exec "$target" -- hostname 2>/dev/null || printf 'pve\n'
  fi
}

# Read a whiptail input or password box and print its value.
_prompt_value() {
  local title="$1" prompt="$2" default="$3" secret="$4" out
  if [[ "$secret" == 1 ]]; then
    out="$(whiptail --title "$title" --passwordbox "$prompt" 10 64 3>&1 1>&2 2>&3)" ||
      return 1
  else
    out="$(whiptail --title "$title" --inputbox "$prompt" 10 64 "$default" 3>&1 1>&2 2>&3)" ||
      return 1
  fi
  printf '%s\n' "$out"
}

# Succeed when a site credential form was supplied.
_has_site_form() {
  [[ -n "${var_site_provisioning_key:-}" ]] ||
    [[ -n "${var_site_id:-}" && -n "${var_site_secret:-}" ]]
}

# Map the legacy Newt variables onto the site credential variables.
_apply_legacy_aliases() {
  if [[ -z "${var_site_id:-}" && -n "${var_newt_id:-}" ]]; then
    var_site_id="$var_newt_id"
  fi
  if [[ -z "${var_site_secret:-}" && -n "${var_newt_secret:-}" ]]; then
    var_site_secret="$var_newt_secret"
  fi
}

# Print the value of NAME_<target> when it is set, otherwise the global NAME
# when this run has exactly one target. The target suffix is `host` or the CTID.
_target_value() {
  local prefix="$1" target="$2" total="$3" name="${1}_$2" value
  value="${!name-}"
  if [[ -z "$value" && "$total" == 1 ]]; then
    name="$prefix"
    value="${!name-}"
  fi
  printf '%s' "$value"
}

# Copy the per-target credentials into the credential globals that the shared
# prompt, validation, and answers helpers read.
_activate_target_credentials() {
  local i="$1"
  var_site_id="${TARGET_SITE_ID[i]-}"
  var_site_secret="${TARGET_SITE_SECRET[i]-}"
  var_site_provisioning_key="${TARGET_SITE_PROVISIONING_KEY[i]-}"
  var_site_name="${TARGET_SITE_NAME[i]-}"
  var_client_id="${TARGET_CLIENT_ID[i]-}"
  var_client_secret="${TARGET_CLIENT_SECRET[i]-}"
}

# Save the credential globals for target index i.
_capture_target_credentials() {
  local i="$1"
  TARGET_SITE_ID[i]="${var_site_id-}"
  TARGET_SITE_SECRET[i]="${var_site_secret-}"
  TARGET_SITE_PROVISIONING_KEY[i]="${var_site_provisioning_key-}"
  TARGET_SITE_NAME[i]="${var_site_name-}"
  TARGET_CLIENT_ID[i]="${var_client_id-}"
  TARGET_CLIENT_SECRET[i]="${var_client_secret-}"
}

# Resolve the unattended credentials for one target into the globals. A
# suffixed variable wins; globals are the fallback only for a single target.
_load_target_credentials() {
  local target="$1" total="$2"
  var_site_id="$(_target_value var_site_id "$target" "$total")"
  var_site_secret="$(_target_value var_site_secret "$target" "$total")"
  var_site_provisioning_key="$(_target_value var_site_provisioning_key "$target" "$total")"
  var_site_name="$(_target_value var_site_name "$target" "$total")"
  var_client_id="$(_target_value var_client_id "$target" "$total")"
  var_client_secret="$(_target_value var_client_secret "$target" "$total")"
}

# Clear only the credentials before asking for the next target. The endpoint
# and the site native toggles stay as shared selections.
_reset_target_credentials() {
  var_site_id=""
  var_site_secret=""
  var_site_provisioning_key=""
  var_site_name=""
  var_client_id=""
  var_client_secret=""
}

# Validate the site native toggles and resolve the interface names before any
# side effect. Both modes enabled with the CLI default name move the main tunnel
# to pangolin-main; any other shared name is ambiguous and fails.
_resolve_site_native() {
  local native="${var_site_native-0}" native_main="${var_site_native_main-0}"
  local interface="${var_site_interface-pangolin}"
  local interface_main="${var_site_interface_main-pangolin}"
  _validate_native_args "$native" "$native_main" "$interface" "$interface_main" || return 1
  if [[ "$native" == 1 && "$native_main" == 1 && "$interface" == "$interface_main" ]]; then
    if [[ "$interface" != pangolin ]]; then
      echo "Both site native modes use the interface name $interface; set var_site_interface and var_site_interface_main to distinct names." >&2
      return 1
    fi
    interface_main="pangolin-main"
    printf 'Note: both native modes use the default interface name; the main tunnel uses pangolin-main.\n' >&2
  fi
  var_site_native="$native"
  var_site_native_main="$native_main"
  var_site_interface="$interface"
  var_site_interface_main="$interface_main"
}

# Print the site configuration on the target. Read-only; prints nothing when the
# file is missing or cannot be read.
_read_target_site_config() {
  local target="$1"
  if [[ "$target" == host ]]; then
    cat "$(p /etc/pangolin/site.json)" 2>/dev/null || true
  else
    pct exec "$target" -- cat /etc/pangolin/site.json 2>/dev/null || true
  fi
}

# Succeed when JSON content holds KEY with a true boolean value.
_json_key_true() {
  local content="$1" key="$2"
  printf '%s' "$content" | grep -qE "\"$key\"[[:space:]]*:[[:space:]]*true"
}

# Succeed when JSON content holds KEY with exactly VALUE as a string.
_json_key_string() {
  local content="$1" key="$2" value="$3" escaped
  escaped="$(printf '%s' "$value" | sed 's/[][\.*^$/]/\\&/g')"
  printf '%s' "$content" | grep -qE "\"$key\"[[:space:]]*:[[:space:]]*\"$escaped\""
}

# Succeed when a site configuration already enables every requested native mode
# with the requested interface names.
_site_native_matches() {
  local content="$1" native="$2" native_main="$3"
  local interface="$4" interface_main="$5"
  if [[ "$native" == 1 ]]; then
    _json_key_true "$content" native || return 1
    _json_key_string "$content" interface "$interface" || return 1
  fi
  if [[ "$native_main" == 1 ]]; then
    _json_key_true "$content" nativeMain || return 1
    _json_key_string "$content" interfaceMain "$interface_main" || return 1
  fi
}

# Succeed when the native toggles can take effect: no site native mode is
# enabled, this run writes a new site configuration, or the existing target
# configuration already matches every requested native mode. A mismatched or
# missing configuration fails so a requested mode is never silently dropped.
_native_config_possible() {
  local target="$1" answers="$2" content
  [[ "$answers" == 1 ]] && return 0
  if ! tun_required 0 "${var_site_native-0}" "${var_site_native_main-0}"; then
    return 0
  fi
  content="$(_read_target_site_config "$target")"
  [[ -n "$content" ]] || return 1
  _site_native_matches "$content" "${var_site_native-0}" "${var_site_native_main-0}" \
    "${var_site_interface-pangolin}" "${var_site_interface_main-pangolin}"
}

# Print a component list for messages.
_components_label() {
  local site="$1" client="$2"
  if [[ "$site" == 1 && "$client" == 1 ]]; then
    printf 'site, client\n'
  elif [[ "$site" == 1 ]]; then
    printf 'site\n'
  else
    printf 'client\n'
  fi
}

# Validate the plan without touching the host. It accepts a site run with no
# credentials when an existing site or legacy install may be reused; the real
# run verifies that before it installs anything.
_validate_plan() {
  local site="$1" client="$2" reconfigure="$3" missing=() partial=0
  if [[ -n "${var_pangolin_endpoint:-}" ]] && ! validate_endpoint "$var_pangolin_endpoint"; then
    echo "Invalid Pangolin endpoint; expected an http(s) URL with a host." >&2
    return 1
  fi
  if [[ -n "${var_site_name:-}" ]] && ! validate_site_name "$var_site_name"; then
    echo "Invalid site name; expected 1-63 characters with no control characters." >&2
    return 1
  fi
  if [[ "$site" == 1 ]]; then
    if [[ -n "${var_site_provisioning_key:-}" ]]; then
      [[ -n "${var_pangolin_endpoint:-}" ]] || missing+=("var_pangolin_endpoint")
    elif [[ -n "${var_site_id:-}" || -n "${var_site_secret:-}" ]]; then
      if [[ -z "${var_site_id:-}" || -z "${var_site_secret:-}" ]]; then
        partial=1
      fi
      [[ -n "${var_pangolin_endpoint:-}" ]] || missing+=("var_pangolin_endpoint")
    fi
    if [[ "$reconfigure" == 1 ]] && ! _has_site_form; then
      missing+=("var_site_provisioning_key or var_site_id and var_site_secret")
    fi
  fi
  if [[ "$client" == 1 ]]; then
    [[ -n "${var_client_id:-}" ]] || missing+=("var_client_id")
    [[ -n "${var_client_secret:-}" ]] || missing+=("var_client_secret")
    [[ -n "${var_pangolin_endpoint:-}" ]] || missing+=("var_pangolin_endpoint")
  fi
  if ((partial == 1)); then
    echo "Site credentials are incomplete; provide var_site_id and var_site_secret together." >&2
    return 1
  fi
  if ((${#missing[@]} > 0)); then
    echo "Missing required values: ${missing[*]}" >&2
    return 1
  fi
  return 0
}

# Print the plan and exit without network, prompts, or filesystem changes.
_print_dry_run() {
  local mode="$1" target="$2" site="$3" client="$4" reconfigure="$5"
  local where="host" prefix="" site_native=0 site_native_main=0 need_tun=0
  local native_label="disabled" main_label="disabled"
  if [[ "$target" != host ]]; then
    where="LXC CTID $target"
    prefix="pct exec $target -- "
  fi
  if [[ "$site" == 1 ]]; then
    site_native="${var_site_native-0}"
    site_native_main="${var_site_native_main-0}"
    [[ "$site_native" == 1 ]] && native_label="enabled"
    [[ "$site_native_main" == 1 ]] && main_label="enabled"
  fi
  if tun_required "$client" "$site_native" "$site_native_main"; then
    need_tun=1
  fi
  printf 'Target: %s\n' "$where"
  printf 'Mode: %s\n' "$mode"
  printf 'Components: %s\n' "$(_components_label "$site" "$client")"
  printf 'Actions:\n'
  printf '  - Validate the target OS floor (Debian 12+, Ubuntu 22.04+, Alpine 3.20+)\n'
  printf '  - Install or verify the Pangolin CLI binary\n'
  if [[ "$site" == 1 ]]; then
    if [[ "$reconfigure" == 1 ]]; then
      printf '  - Replace the site configuration with the provided credentials\n'
    elif _has_site_form; then
      printf '  - Install the site configuration from the private answers directory\n'
    else
      printf '  - Reuse the existing site configuration, or migrate a legacy site or Newt install\n'
    fi
    if [[ -n "${var_site_provisioning_key:-}" ]]; then
      printf '  - Note: provisioning keys require tier3/enterprise; with "approve new sites" off the site stays pending\n'
      if [[ "$reconfigure" == 1 ]]; then
        printf '  - Note: reconfiguring with a provisioning key creates a second server-side site\n'
      fi
    fi
    printf '  - Site native client tunnels: %s (interface %s)\n' \
      "$native_label" "${var_site_interface-pangolin}"
    printf '  - Site native main tunnel: %s (interface %s)\n' \
      "$main_label" "${var_site_interface_main-pangolin}"
    if [[ "$reconfigure" != 1 ]] && ! _has_site_form &&
      [[ "$site_native" == 1 || "$site_native_main" == 1 ]]; then
      printf '  - Note: native interface settings are applied only on create or reconfigure; reuse requires the existing site configuration to match, otherwise set var_reconfigure=1\n'
    fi
    printf '  - Install the pangolin-site service and verify provisioning\n'
    printf '  - Check status with: %spangolin service status site\n' "$prefix"
  fi
  if [[ "$client" == 1 ]]; then
    printf '  - Install the pangolin-client service with the provided credentials\n'
    printf '  - Check status with: %spangolin service status client\n' "$prefix"
  fi
  if [[ "$need_tun" == 1 ]]; then
    if [[ "$target" == host ]]; then
      printf '  - Ensure /dev/net/tun exists on the host; native site interfaces and client mode need it\n'
    else
      printf '  - Apply TUN passthrough and restart CTID %s gracefully when the config changes\n' \
        "$target"
    fi
  fi
  if [[ "$target" != host ]]; then
    printf '  - Update the LXC tags for the selected components\n'
  fi
  printf '  - Remove the private answers directory on exit\n'
}

# Succeed when the target already has a verified site configuration. This is a
# read-only probe; no secret leaves the target.
_target_site_verified() {
  local target="$1"
  if [[ "$target" == host ]]; then
    site_config_has_credentials "$(p /etc/pangolin/site.json)"
    return
  fi
  pct exec "$target" -- sh -c \
    'grep -q "\"id\"[[:space:]]*:" /etc/pangolin/site.json 2>/dev/null && grep -q "\"secret\"[[:space:]]*:" /etc/pangolin/site.json 2>/dev/null && ! grep -q "\"provisioningKey\"[[:space:]]*:" /etc/pangolin/site.json 2>/dev/null'
}

# Succeed when a legacy site env or a standalone Newt env exists on the target.
_target_has_legacy_site() {
  local target="$1"
  if [[ "$target" == host ]]; then
    [[ -f "$(p /etc/pangolin/pangolin-site.env)" || -f "$(p /etc/newt/newt.env)" ]]
    return
  fi
  pct exec "$target" -- sh -c \
    'test -f /etc/pangolin/pangolin-site.env || test -f /etc/newt/newt.env'
}

# Start a stopped LXC so its OS and configuration can be read.
_ensure_lxc_running() {
  local ctid="$1" status i=0
  if ! command -v pct >/dev/null 2>&1; then
    echo "pct is required to install into an LXC container" >&2
    return 1
  fi
  status="$(pct status "$ctid" 2>/dev/null)" || {
    echo "Cannot read the status of CTID $ctid" >&2
    return 1
  }
  if [[ "$status" == *running* ]]; then
    return 0
  fi
  pct start "$ctid" || {
    echo "Failed to start CTID $ctid" >&2
    return 1
  }
  while ((i < 60)); do
    if pct status "$ctid" 2>/dev/null | grep -q running; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "CTID $ctid did not reach the running state" >&2
  return 1
}

# Apply TUN passthrough to a client LXC. The container is restarted gracefully
# only when the config actually changed.
_apply_lxc_tun() {
  local ctid="$1" need_tun="$2" status i=0
  [[ "$need_tun" == 1 ]] || return 0
  TUN_CHANGED=0
  ensure_tun_config "/etc/pve/lxc/$ctid.conf" || {
    echo "Failed to add TUN passthrough to /etc/pve/lxc/$ctid.conf" >&2
    return 1
  }
  [[ "$TUN_CHANGED" == 1 ]] || return 0
  status="$(pct status "$ctid" 2>/dev/null)" || {
    echo "Cannot read the status of CTID $ctid" >&2
    return 1
  }
  if [[ "$status" == *running* ]]; then
    if ! pct shutdown "$ctid" --timeout 60; then
      echo "Failed to shut down CTID $ctid gracefully" >&2
      return 1
    fi
  fi
  pct start "$ctid" || {
    echo "Failed to start CTID $ctid" >&2
    return 1
  }
  while ((i < 60)); do
    if pct status "$ctid" 2>/dev/null | grep -q running; then
      msg_ok "Restarted CTID $ctid after changing TUN passthrough."
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "CTID $ctid did not reach the running state" >&2
  return 1
}

# Client mode on the host needs the TUN device. Load the module when it is not
# present and fail before installing if the device still cannot be opened.
_ensure_host_tun() {
  local device="${1:-/dev/net/tun}"
  [[ -e "$device" ]] && return 0
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun >/dev/null 2>&1 || true
  fi
  if [[ ! -e "$device" ]]; then
    echo "Client mode requires $device. Load the tun module (modprobe tun) or enable it on the host, then rerun." >&2
    return 1
  fi
}

# The payload is bash and Alpine templates ship without it. Install bash from
# the container's own package manager before the payload is pushed.
_ensure_lxc_runtime() {
  local ctid="$1"
  if pct exec "$ctid" -- sh -c \
    'command -v bash >/dev/null 2>&1 && command -v curl >/dev/null 2>&1'; then
    return 0
  fi
  if pct exec "$ctid" -- sh -c 'command -v apk >/dev/null 2>&1'; then
    pct exec "$ctid" -- apk add --no-cache bash ca-certificates curl || return 1
  elif pct exec "$ctid" -- sh -c 'command -v apt-get >/dev/null 2>&1'; then
    pct exec "$ctid" -- sh -c \
      'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash ca-certificates curl' ||
      return 1
  else
    echo "CTID $ctid has no supported package manager to install bash" >&2
    return 1
  fi
  pct exec "$ctid" -- bash -c true
}

# Collect interactive credentials. Existing verified site configs are offered
# as reuse or replace; client credentials are always prompted when missing. A
# site enrollment ends with the native interface toggles; names are never
# prompted.
_prompt_inputs() {
  local target="$1" site="$2" client="$3" choice default_name
  local net_choice net_state main_state enrolling=0
  if [[ "$site" == 1 ]]; then
    if _target_site_verified "$target" && [[ "${var_reconfigure:-0}" != 1 ]]; then
      choice="$(whiptail --title "Existing site" --menu \
        "A verified site configuration already exists." 15 64 2 \
        reuse "Reuse the existing site configuration" \
        replace "Replace it with new credentials" 3>&1 1>&2 2>&3)" || return 1
      if [[ "$choice" == replace ]]; then
        var_reconfigure=1
      fi
    fi
    if [[ "${var_reconfigure:-0}" == 1 ]] || ! _target_site_verified "$target"; then
      if ! _target_has_legacy_site "$target" || [[ "${var_reconfigure:-0}" == 1 ]]; then
        enrolling=1
        if [[ -z "${var_pangolin_endpoint:-}" ]]; then
          var_pangolin_endpoint="$(whiptail --title "Pangolin Addon" \
            --inputbox "Pangolin endpoint" 10 64 "https://app.pangolin.net" 3>&1 1>&2 2>&3)" ||
            return 1
        fi
        choice="$(whiptail --title "Site credentials" --menu \
          "Site credentials:" 15 64 2 \
          static "Site ID + secret (works on every Pangolin edition)" \
          provisioning "Site provisioning key (tier3/enterprise)" 3>&1 1>&2 2>&3)" || return 1
        if [[ "$choice" == provisioning ]]; then
          var_site_id=""
          var_site_secret=""
          if [[ -z "${var_site_provisioning_key:-}" ]]; then
            var_site_provisioning_key="$(_prompt_value "Site provisioning key" \
              "Site provisioning key (spk-...)" "" 1)" || return 1
          fi
          if [[ -z "${var_site_name:-}" ]]; then
            default_name="$(_default_site_name "$target")"
            var_site_name="$(_prompt_value "Site name" "Site name" "$default_name" 0)" ||
              return 1
          fi
        else
          var_site_provisioning_key=""
          if [[ -z "${var_site_id:-}" ]]; then
            var_site_id="$(_prompt_value "Site ID" "Site ID" "" 0)" || return 1
          fi
          if [[ -z "${var_site_secret:-}" ]]; then
            var_site_secret="$(_prompt_value "Site secret" "Site secret" "" 1)" || return 1
          fi
        fi
      fi
    elif _has_site_form; then
      msg_warn "Ignoring new site credentials; the verified site configuration is reused. Set var_reconfigure=1 to replace it."
    fi
    if [[ "$enrolling" == 1 ]]; then
      net_state="OFF"
      main_state="OFF"
      [[ "${var_site_native-0}" == 1 ]] && net_state="ON"
      [[ "${var_site_native_main-0}" == 1 ]] && main_state="ON"
      net_choice="$(whiptail --title "Site networking" --checklist \
        "Site networking:" 15 74 2 \
        main "native main tunnel (kernel interface, needs TUN)" "$main_state" \
        client "native client tunnels (kernel interface, needs TUN)" "$net_state" \
        3>&1 1>&2 2>&3)" || return 1
      var_site_native=0
      var_site_native_main=0
      case "$net_choice" in
      *'"client"'*) var_site_native=1 ;;
      esac
      case "$net_choice" in
      *'"main"'*) var_site_native_main=1 ;;
      esac
    fi
  fi
  if [[ "$client" == 1 ]]; then
    if [[ -z "${var_pangolin_endpoint:-}" ]]; then
      var_pangolin_endpoint="$(whiptail --title "Pangolin Addon" \
        --inputbox "Pangolin endpoint" 10 64 "https://app.pangolin.net" 3>&1 1>&2 2>&3)" ||
        return 1
    fi
    if [[ -z "${var_client_id:-}" ]]; then
      var_client_id="$(_prompt_value "Client ID" "Machine client ID" "" 0)" || return 1
    fi
    if [[ -z "${var_client_secret:-}" ]]; then
      var_client_secret="$(_prompt_value "Client secret" "Machine client secret" "" 1)" ||
        return 1
    fi
  fi
}

# Decide whether new site answers are needed. A verified config is reused
# unless var_reconfigure=1; a legacy site or Newt install is migrated in place.
_resolve_site_answers() {
  local target="$1" reconfigure="$2" site_answers=0
  if [[ "$reconfigure" == 1 ]]; then
    site_answers=1
  elif _target_site_verified "$target"; then
    if _has_site_form; then
      msg_warn "Ignoring new site credentials; the verified site configuration is reused. Set var_reconfigure=1 to replace it." >&2
    fi
    site_answers=0
  elif _has_site_form; then
    site_answers=1
  elif _target_has_legacy_site "$target"; then
    msg_warn "A legacy site or Newt installation will be migrated." >&2
    site_answers=0
  else
    msg_error "No site configuration found. Provide a provisioning key or a site ID and secret."
    return 1
  fi
  printf '%s\n' "$site_answers"
}

# Throw away every private answers directory on every exit path, including the
# copies pushed into each LXC container.
_cleanup_answers() {
  local dir target
  for dir in "${TARGET_ANSWERS[@]}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
  for target in "${REMOTE_TARGETS[@]}"; do
    _remove_remote_answers "$target"
  done
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "${ANSWERS_DIR:-}" ]]; then
    rm -rf "$ANSWERS_DIR"
  fi
  if [[ -n "${REMOTE_TARGET:-}" ]]; then
    _remove_remote_answers "$REMOTE_TARGET"
  fi
}

# Remove the answers copy from one LXC. A missing or stopped container is fine:
# the run must not fail because cleanup could not reach it.
_remove_remote_answers() {
  local target="${1:-}"
  [[ -n "$target" && "$target" != host ]] || return 0
  pct exec "$target" -- rm -rf /root/.pangolin-addon >/dev/null 2>&1 || true
}

# Print the commands the operator uses to confirm and inspect the services.
_print_next_steps() {
  local target="$1" site="$2" client="$3" prefix=""
  if [[ "$target" != host ]]; then
    prefix="pct exec $target -- "
  fi
  if [[ "$site" == 1 ]]; then
    msg_ok "Pangolin site is installed."
    printf '  %spangolin service status site\n' "$prefix"
    printf '  %spangolin service logs site\n' "$prefix"
  fi
  if [[ "$client" == 1 ]]; then
    msg_ok "Pangolin client is installed."
    printf '  %spangolin service status client\n' "$prefix"
    printf '  %spangolin service logs client\n' "$prefix"
  fi
}

# Warn about provisioning-key limitations before an install uses one. Covers
# both interactive and unattended input because it runs after input resolution.
_warn_provisioning_risks() {
  local reconfigure="$1" site="$2"
  [[ "$site" == 1 ]] || return 0
  [[ -n "${var_site_provisioning_key:-}" ]] || return 0
  msg_warn "Provisioning keys require Pangolin tier3/enterprise. If \"approve new sites\" is disabled, the site stays pending until an operator approves it." >&2
  if [[ "$reconfigure" == 1 ]]; then
    msg_warn "Reconfiguring with a provisioning key creates a second server-side site; delete the old site in the Pangolin dashboard." >&2
  fi
}

# Read the payload's verified-component marker and tag an LXC target with only
# the components that actually verified. Sets VERIFIED_SITE/VERIFIED_CLIENT.
_apply_verified_tags() {
  local target="$1" answers="$2" content="" line
  VERIFIED_SITE=0
  VERIFIED_CLIENT=0
  if [[ "$target" == host ]]; then
    content="$(cat "$answers/verified" 2>/dev/null || true)"
  else
    content="$(pct exec "$target" -- cat /root/.pangolin-addon/verified 2>/dev/null || true)"
  fi
  while IFS= read -r line; do
    case "$line" in
    site) VERIFIED_SITE=1 ;;
    client) VERIFIED_CLIENT=1 ;;
    esac
  done <<<"$content"
  if [[ "$target" != host ]] && [[ "$VERIFIED_SITE" == 1 || "$VERIFIED_CLIENT" == 1 ]]; then
    apply_lxc_tags "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT" || {
      msg_warn "The install finished, but the LXC tags could not be updated." >&2
    }
  fi
}

# Create one private answers directory for a target inside the run directory.
_new_answers_dir() {
  local dir
  dir="$(mktemp -d "${WORK_DIR}/answers.XXXXXX")" || return 1
  chmod 0700 "$dir" || {
    rm -rf "$dir"
    return 1
  }
  printf '%s\n' "$dir"
}

# Run the shared payload for one target. The host runs it in place; an LXC gets
# the file and the per-target answers directory pushed, then runs them. Secrets
# never appear in an argument value or in `pct exec -- env`.
_run_target_payload() {
  local target="$1" answers="$2" rc=0
  local -a runenv=()
  if [[ "$target" == host ]]; then
    bash "$WORK_DIR/payload.sh" "$answers" || rc=$?
    return "$rc"
  fi
  if ! push_payload "$target" "$WORK_DIR/payload.sh" "$answers"; then
    msg_error "Failed to push the Pangolin install payload to CTID $target"
    return 1
  fi
  runenv=(PANGOLIN_ROOT=)
  if [[ -n "${var_pangolin_cli_version:-}" ]]; then
    runenv+=("var_pangolin_cli_version=$var_pangolin_cli_version")
  fi
  if [[ -n "${var_pangolin_cli_sha256:-}" ]]; then
    runenv+=("var_pangolin_cli_sha256=$var_pangolin_cli_sha256")
  fi
  pct exec "$target" -- env "${runenv[@]}" \
    bash /root/.pangolin-addon/payload.sh /root/.pangolin-addon || rc=$?
  return "$rc"
}

# Print the result of every target after the loop.
_print_run_summary() {
  local i
  printf '\nPangolin addon summary\n'
  for ((i = 0; i < ${#TARGETS[@]}; i++)); do
    printf '  %s: %s\n' "${TARGETS[i]}" "${TARGET_STATUS[i]:-failed}"
  done
}

# Install one target from the shared selections. Returns non-zero for that
# target only; the caller continues with the rest. Credentials for the target
# come from the per-target arrays, except in interactive mode where the prompts
# fill them for this target.
_install_target() {
  local target="$1" index="$2" site="$3" client="$4" shared_reconfigure="$5"
  local reconfigure="${TARGET_RECONFIGURE[index]:-$shared_reconfigure}"
  local site_answers=0 need_tun=0 payload_rc=0 name="" answers=""

  if _is_noninteractive; then
    _activate_target_credentials "$index"
  else
    _reset_target_credentials
    var_reconfigure="$shared_reconfigure"
  fi

  if [[ "$target" != host ]]; then
    if ! _ensure_lxc_running "$target"; then
      msg_error "Target $target: the container could not be started."
      return 1
    fi
  fi
  _validate_target_os "$target" || return 1

  if ! _is_noninteractive; then
    _prompt_inputs "$target" "$site" "$client" || return 1
    reconfigure="${var_reconfigure:-0}"
    [[ "$reconfigure" == 1 ]] || reconfigure=0
    TARGET_RECONFIGURE[index]="$reconfigure"
    # The interactive site checkboxes can change the shared native modes.
    if [[ "$site" == 1 ]]; then
      _resolve_site_native || return 1
    fi
  fi

  _validate_plan "$site" "$client" "$reconfigure" || return 1
  _warn_provisioning_risks "$reconfigure" "$site"

  if [[ "$site" == 1 ]]; then
    site_answers="$(_resolve_site_answers "$target" "$reconfigure")" || return 1
    if ! _native_config_possible "$target" "$site_answers"; then
      msg_error "Native site interfaces are enabled but the existing site configuration does not match; set var_reconfigure=1 to apply them."
      return 1
    fi
  fi

  # The final components and native toggles decide whether TUN is needed. The
  # interactive checkboxes and the reuse decision run first, so this stays after
  # input resolution and never touches a host that will not be changed.
  if [[ "$client" == 1 ]]; then
    need_tun=1
  fi
  if [[ "$site" == 1 ]] && tun_required 0 "$var_site_native" "$var_site_native_main"; then
    need_tun=1
  fi
  if [[ "$target" == host ]]; then
    if [[ "$need_tun" == 1 ]]; then
      _ensure_host_tun || return 1
    fi
  else
    _apply_lxc_tun "$target" "$need_tun" || return 1
    if ! _ensure_lxc_runtime "$target"; then
      msg_error "CTID $target does not have a usable bash and curl runtime"
      return 1
    fi
  fi

  answers="$(_new_answers_dir)" || return 1
  TARGET_ANSWERS+=("$answers")
  ANSWERS_DIR="$answers"
  if [[ "$target" != host ]]; then
    REMOTE_TARGETS+=("$target")
  fi

  write_private_file "$answers/flags" \
    "$(printf 'SITE=%s\nCLIENT=%s\nRECONFIGURE=%s\nTARGET=%s' \
      "$site" "$client" "$reconfigure" "$target")" || return 1

  if [[ "$site" == 1 && "$site_answers" == 1 ]]; then
    if [[ -n "${var_site_provisioning_key:-}" ]]; then
      name="${var_site_name:-}"
      if [[ -z "$name" ]]; then
        name="$(_default_site_name "$target")"
      fi
      if ! validate_site_name "$name"; then
        msg_error "Invalid site name; expected 1-63 characters with no control characters."
        return 1
      fi
      build_site_answers "$answers" "$var_pangolin_endpoint" \
        "$var_site_provisioning_key" "$name" - - \
        "$var_site_native" "$var_site_native_main" \
        "$var_site_interface" "$var_site_interface_main" || return 1
    else
      build_site_answers "$answers" "$var_pangolin_endpoint" - - \
        "$var_site_id" "$var_site_secret" \
        "$var_site_native" "$var_site_native_main" \
        "$var_site_interface" "$var_site_interface_main" || return 1
    fi
  fi
  if [[ "$client" == 1 ]]; then
    build_client_answers "$answers" "$var_pangolin_endpoint" \
      "$var_client_id" "$var_client_secret" || return 1
  fi

  payload_rc=0
  _run_target_payload "$target" "$answers" || payload_rc=$?

  _apply_verified_tags "$target" "$answers"
  # The remote copy is no longer needed once the marker is read.
  _remove_remote_answers "$target"
  if ((payload_rc != 0)); then
    msg_error "The Pangolin install failed on $target. Components that were verified stay installed."
    return 1
  fi

  if [[ "$VERIFIED_SITE" == 0 && "$VERIFIED_CLIENT" == 0 ]]; then
    VERIFIED_SITE="$site"
    VERIFIED_CLIENT="$client"
  fi
  _print_next_steps "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT"
  return 0
}

# Full interactive or unattended flow. Secrets stay in the mode 0700 answers
# directories and never enter a pct argument value or a log line.
main() {
  local mode="" target="" site=0 client=0 reconfigure=0
  local var_site_native="${var_site_native-0}"
  local var_site_native_main="${var_site_native_main-0}"
  local var_site_interface="${var_site_interface-pangolin}"
  local var_site_interface_main="${var_site_interface_main-pangolin}"
  local -a missing=()
  local i total=0 target_out="" failed=0

  ANSWERS_DIR=""
  REMOTE_TARGET=""
  WORK_DIR=""
  TARGETS=()
  TARGET_ANSWERS=()
  REMOTE_TARGETS=()
  TARGET_STATUS=()
  TARGET_RECONFIGURE=()
  TARGET_SITE_ID=()
  TARGET_SITE_SECRET=()
  TARGET_SITE_PROVISIONING_KEY=()
  TARGET_SITE_NAME=()
  TARGET_CLIENT_ID=()
  TARGET_CLIENT_SECRET=()

  PANGOLIN_DRY_RUN="${PANGOLIN_DRY_RUN:-0}"
  # A non-1 value must never turn a requested dry run into a live install.
  case "$PANGOLIN_DRY_RUN" in
  0 | 1) ;;
  true) PANGOLIN_DRY_RUN=1 ;;
  false) PANGOLIN_DRY_RUN=0 ;;
  *)
    echo "Invalid PANGOLIN_DRY_RUN: $PANGOLIN_DRY_RUN (expected 0 or 1)" >&2
    return 1
    ;;
  esac

  reconfigure="${var_reconfigure:-0}"
  if [[ "$reconfigure" != 0 && "$reconfigure" != 1 ]]; then
    echo "Invalid var_reconfigure: $reconfigure (expected 0 or 1)" >&2
    return 1
  fi

  # Dry run must never open whiptail: require the unattended selectors first.
  if [[ "$PANGOLIN_DRY_RUN" == 1 ]]; then
    missing=()
    [[ -n "${var_mode:-}" ]] || missing+=("var_mode")
    [[ -n "${var_targets:-}${var_target:-}" ]] || missing+=("var_targets or var_target")
    if ((${#missing[@]} > 0)); then
      echo "Missing required values: ${missing[*]}" >&2
      return 1
    fi
  fi

  mode="$(_resolve_mode)" || return 1
  read -r site client <<<"$(components_from_mode "$mode")" || return 1
  target_out="$(_resolve_targets)" || return 1
  mapfile -t TARGETS <<<"$target_out"
  total=${#TARGETS[@]}
  if ((total == 0)); then
    echo "No targets selected (expected host or CTIDs)" >&2
    return 1
  fi
  _apply_legacy_aliases
  # Validate the site native toggles before the dry run or any host change.
  if [[ "$site" == 1 ]]; then
    _resolve_site_native || return 1
  fi

  # The shared reconfigure flag seeds every target. Unattended credentials are
  # resolved once per target here, before any host is touched.
  for ((i = 0; i < total; i++)); do
    TARGET_RECONFIGURE[i]="$reconfigure"
  done
  if _is_noninteractive; then
    for ((i = 0; i < total; i++)); do
      _load_target_credentials "${TARGETS[i]}" "$total"
      _capture_target_credentials "$i"
    done
  fi

  if [[ "$PANGOLIN_DRY_RUN" == 1 ]]; then
    printf 'Pangolin addon dry run\n'
    printf 'Selected targets: %s\n' "$total"
    for ((i = 0; i < total; i++)); do
      _activate_target_credentials "$i"
      _validate_plan "$site" "$client" "$reconfigure" || return 1
      _print_dry_run "$mode" "${TARGETS[i]}" "$site" "$client" "$reconfigure"
      printf '\n'
    done
    return 0
  fi

  if ! _ensure_curl; then
    echo "curl is required to fetch the Pangolin install payload" >&2
    return 1
  fi
  _load_core
  # Core dev trace would print credential assignments. This addon never traces.
  set +x
  # The banner is cosmetic; its header fetch must not add noise to the run.
  header_info 2>/dev/null || true
  if ! require_pve_host; then
    return 232
  fi

  WORK_DIR="$(mktemp -d)" || return 1
  chmod 0700 "$WORK_DIR" || {
    rm -rf "$WORK_DIR"
    WORK_DIR=""
    return 1
  }
  trap _cleanup_answers EXIT

  # One payload copy serves every target.
  if ! fetch_payload "$WORK_DIR/payload.sh"; then
    msg_error "Failed to fetch the Pangolin install payload from $PANGOLIN_PAYLOAD_URL"
    return 1
  fi
  if ! bash -n "$WORK_DIR/payload.sh"; then
    msg_error "The fetched Pangolin install payload failed bash -n"
    return 1
  fi
  # shellcheck disable=SC1090,SC1091
  source "$WORK_DIR/payload.sh"

  if [[ -n "${var_pangolin_cli_version:-}" ]]; then
    export var_pangolin_cli_version
  fi
  if [[ -n "${var_pangolin_cli_sha256:-}" ]]; then
    export var_pangolin_cli_sha256
  fi

  for ((i = 0; i < total; i++)); do
    target="${TARGETS[i]}"
    if _install_target "$target" "$i" "$site" "$client" "$reconfigure"; then
      TARGET_STATUS[i]="ok ($(_components_label "$VERIFIED_SITE" "$VERIFIED_CLIENT"))"
      msg_ok "Target $target: succeeded."
    else
      TARGET_STATUS[i]="failed"
      failed=$((failed + 1))
      if ((i + 1 < total)); then
        msg_error "Target $target failed; continuing with the remaining targets."
      else
        msg_error "Target $target failed."
      fi
    fi
  done

  _print_run_summary
  ((failed == 0)) || return 1
  return 0
}

if [[ "${PANGOLIN_TEST:-0}" != 1 ]] &&
  { [[ -z "${BASH_SOURCE[0]:-}" ]] ||
    [[ "${BASH_SOURCE[0]}" == "$0" ]] ||
    [[ "${BASH_SOURCE[0]}" == /dev/fd/* ]]; }; then
  main "$@"
fi
