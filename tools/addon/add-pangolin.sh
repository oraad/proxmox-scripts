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
#   Multi-site: var_sites="orga org-b"    site labels per run (default
#              "default", at most 8). var_sites_<host|CTID> overrides the list
#              for one target. var_multi_sites=1 (1/true/yes) requests the
#              per-slug layout even with a single "default" slug.
#              var_site_ssh_owner=default|<slug>|none picks the slug that keeps
#              the embedded SSH daemon. var_site_native and
#              var_site_native_main are shared booleans. Interface overrides
#              resolve in order: var_site_interface_<slug>_<target>,
#              var_site_interface_<slug>, var_site_interface_<target>,
#              var_site_interface, then the generated per-slug name. Site
#              credential variables acquire the same slug suffixes:
#              var_site_id_<slug>_<target> wins first.
#              With one "default" slug and an unconverted target the run stays
#              on the legacy single-site path.
#
# Mode, endpoint, site native toggles, SSH owner, and var_reconfigure are
# shared by every target. Each target gets its own private answers directory
# and install run.

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
# Slugs the payload verified, space-separated, and the service backend it
# reported. Only multi-site runs emit these markers.
VERIFIED_SLUGS=""
VERIFIED_BACKEND="single"
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
# Per-target site slug selections (space-separated) and the effective
# multi-site decision, parallel to TARGETS.
TARGET_SLUGS=()
TARGET_MULTI=()
# Site label plans chosen by the interactive editor, parallel to TARGETS. An
# empty entry means the target kept the explicit or default selection.
TARGET_SLUG_PLANS=()
# Per-target "site <slug>: verified|failed" summary lines, parallel to TARGETS.
TARGET_SLUG_STATUS=()
# Site credentials collected interactively for a (slug,target) pair, keyed
# "slug|target". Unattended runs resolve the same values from the environment.
declare -A SITE_PAIR_ID=()
declare -A SITE_PAIR_SECRET=()
declare -A SITE_PAIR_KEY=()
declare -A SITE_PAIR_NAME=()
# Set by main() to 1 once the raw operator interface overrides have been
# captured, so per-slug resolution can tell an unset shared interface (use the
# generated per-slug name) from an explicit one (share it across slugs).
SITE_INTERFACE_CAPTURED=0
SITE_INTERFACE_RAW=""
SITE_INTERFACE_MAIN_RAW=""
# Static IDs already used in this run, collected before any mutation, so a
# duplicate fails the affected target instead of the Pangolin server.
SEEN_SITE_IDS=$'\n'
SEEN_CLIENT_IDS=$'\n'
# The SSH owner menu is a shared selection like the endpoint; it is asked at
# most once per run. The label editor is target-aware: it stores the last
# selection in SITE_LABEL_PLAN and the caller records it per target.
SITE_OWNER_PROMPTED=0
SITE_LABEL_PLAN=""
# Slug plan for the target being processed, set by _resolve_target_slug_plan.
SLUG_LIST=""
SLUG_TOTAL=1
SLUG_MULTI=0
SLUG_ARRAY=(default)
# Private run directory that holds the shared payload and the answers dirs.
WORK_DIR=""
# The site native checklist is a shared selection; it is asked at most once.
NATIVE_PROMPTED=0

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

# Succeed when the site slug is a valid local site label: 1-10 characters,
# starting with a lowercase letter, using lowercase letters, digits, and inner
# hyphens, ending with a letter or digit. `default` is the legacy single-site
# label and matches this pattern. `host` is reserved: it is the host target's
# environment suffix, and a host slug would collide with it.
validate_site_slug() {
  local slug="${1:-}"
  [[ "$slug" != host ]] || return 1
  [[ "$slug" =~ ^[a-z]([a-z0-9-]{0,8}[a-z0-9])?$ ]]
}

# Succeed when the site SSH owner is unset, `none`, or an exact slug from the
# newline-delimited list. The message names only the sanitized owner, never
# credentials, and control characters are stripped so operator input cannot
# forge a second log line.
validate_site_ssh_owner() {
  local owner="${1:-}" slugs="${2:-}" line
  [[ -z "$owner" || "$owner" == none ]] && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$owner" ]] && return 0
  done <<<"$slugs"
  echo "Invalid site SSH owner: ${owner//[[:cntrl:]]/} (expected one of the selected site slugs or none)" >&2
  return 1
}

# Succeed when a slug must disable its embedded SSH daemon. Exactly one slug
# owns the host auth daemon: an empty or `none` owner disables every slug,
# and any slug that is not the owner disables itself.
site_ssh_disabled() {
  local owner="${1:-}" slug="${2:-}"
  [[ -n "$owner" && "$owner" != none && "$owner" == "$slug" ]] && return 1
  return 0
}

# Succeed when every nonblank interface name appears at most once. Blank
# lines are ignored. The message names only interface names, never credentials.
interface_names_unique() {
  local names="${1:-}" line seen=$'\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$seen" == *$'\n'"$line"$'\n'* ]]; then
      echo "Duplicate interface name: $line (each native interface name may be used only once)" >&2
      return 1
    fi
    seen+="$line"$'\n'
  done <<<"$names"
}

# Succeed when a network interface already exists on the target. Read-only:
# `ip link show` exits 0 only for an existing name.
_interface_exists_on_target() {
  local target="${1:-}" name="${2:-}"
  [[ -n "$name" ]] || return 1
  if [[ "$target" == host ]]; then
    ip link show "$name" >/dev/null 2>&1
  else
    pct exec "$target" -- ip link show "$name" >/dev/null 2>&1
  fi
}

# Reject blank, invalid, duplicate, or already-existing interface names for a
# target before any native interface is created. Every name is validated and
# deduplicated first, so the target is queried only with safe names, once per
# distinct name, and the messages never contain credentials.
validate_interface_names_on_target() {
  local target="${1:-}" names="${2:-}" line
  local rule="1-15 characters, starting with a letter, using letters, digits, _, -, or ."
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      echo "Invalid interface name: empty (expected $rule)" >&2
      return 1
    fi
    if ! validate_interface_name "$line"; then
      echo "Invalid interface name: $line (expected $rule)" >&2
      return 1
    fi
  done <<<"$names"
  interface_names_unique "$names" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if _interface_exists_on_target "$target" "$line"; then
      echo "Interface $line already exists on target $target; native Pangolin interfaces need a free name." >&2
      return 1
    fi
  done <<<"$names"
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

# Write a site configuration JSON to an exact path for a provisioning key or
# for static credentials. The trailing native arguments are "native nativeMain
# interface interfaceMain"; a dash means "not supplied" only for the credential
# fields. disableSsh=1 adds the SSH opt-out key for a non-owner slug. Every
# value is validated before the parent directory or the file is created, so a
# rejected run leaves no answers behind. The parent is private mode 0700 and
# the file mode 0600: it always holds credentials. The key wins when both
# credential forms are present.
build_site_answers_to_path() {
  local path="$1" endpoint="$2" key="$3" name="$4" id="$5" secret="$6"
  local native="${7-0}" native_main="${8-0}" interface="${9-pangolin}"
  local interface_main="${10-pangolin}" disable_ssh="${11-0}"
  local config dir
  validate_endpoint "$endpoint" || {
    echo "Invalid Pangolin endpoint: $endpoint" >&2
    return 1
  }
  _validate_native_args "$native" "$native_main" "$interface" "$interface_main" || return 1
  validate_native_flag "$disable_ssh" || {
    echo "Invalid disableSsh flag: $disable_ssh (expected 0 or 1)" >&2
    return 1
  }
  if [[ "$key" != "-" && -n "$key" ]]; then
    [[ "$name" == "-" ]] && name=""
    config="$(site_config_provisioning "$endpoint" "$key" "$name" \
      "$native" "$native_main" "$interface" "$interface_main" "$disable_ssh")"
  else
    if [[ "$id" == "-" || -z "$id" || "$secret" == "-" || -z "$secret" ]]; then
      echo "Site answers need a provisioning key or an id and secret" >&2
      return 1
    fi
    config="$(site_config_static "$endpoint" "$id" "$secret" \
      "$native" "$native_main" "$interface" "$interface_main" "$disable_ssh")"
  fi
  dir="$(dirname "$path")"
  case "$path" in
  /*) ;;
  *)
    echo "build_site_answers_to_path: an absolute config path is required" >&2
    return 1
    ;;
  esac
  if [[ -z "$path" || "$dir" == "/" ]]; then
    echo "build_site_answers_to_path: a nested config path is required" >&2
    return 1
  fi
  install -d -m 0700 "$dir" || return 1
  # install -d only applies -m when it creates the directory. Force the mode
  # so a sites/ directory made by an earlier slug still guarantees 0700 for
  # this credential-bearing config.
  chmod 0700 "$dir" || return 1
  write_private_file "$path" "$config"
}

# Write <dir>/site.json with the site answers for one target. The optional
# trailing arguments are the native toggles and the disableSsh flag; a flag of
# 0 keeps the legacy single-site JSON byte-identical.
build_site_answers() {
  local dir="$1"
  build_site_answers_to_path "$dir/site.json" "${@:2}"
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

# Pangolin addon banner. The community-scripts core header is generic and shows
# the wrong product art for this addon.
pangolin_header() {
  [[ -t 1 ]] && clear 2>/dev/null || true
  cat <<'EOF'
  ____                         _ _
 |  _ \ __ _ _ __   __ _  ___ | (_)_ __
 | |_) / _` | '_ \ / _` |/ _ \| | | '_ \
 |  __/ (_| | | | | (_| | (_) | | | | | |
 |_|   \__,_|_| |_|\__, |\___/|_|_|_| |_|
                   |___/

   Pangolin Addon (CLI)

EOF
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

# Split a space-, tab-, comma-, or newline-separated list into the named
# array. Unlike unquoted word splitting this never expands wildcards, and
# empty fields are dropped.
_split_words() {
  local -n _split_out="$1"
  local raw="${2:-}"
  raw="${raw//$'\n'/ }"
  raw="${raw//,/ }"
  IFS=$' \t' read -r -a _split_out <<<"$raw"
}

# Print one normalized target per line: `host` or a CTID without leading zeros.
# Accepts a space- or comma-separated list. Rejects non-numeric values, CTID 0,
# and duplicates (including leading-zero spellings).
_parse_targets() {
  local token seen=" " ctid
  local -a tokens=()
  _split_words tokens "${1:-}"
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

# Print one validated site slug per line, in input order. Accepts a space- or
# comma-separated list. Rejects an empty selection, the reserved slug `host`,
# an invalid slug, a duplicate, and more than 8 slugs.
_parse_sites() {
  local token seen=" "
  local -a tokens=()
  _split_words tokens "${1:-}"
  if ((${#tokens[@]} == 0)); then
    echo "No sites selected (expected one or more slugs)" >&2
    return 1
  fi
  if ((${#tokens[@]} > 8)); then
    echo "Too many site slugs: ${#tokens[@]} (maximum 8)" >&2
    return 1
  fi
  for token in "${tokens[@]}"; do
    if [[ "$token" == host ]]; then
      echo "Reserved site slug: host (targets already use the host suffix)" >&2
      return 1
    fi
    if ! validate_site_slug "$token"; then
      echo "Invalid site slug: ${token//[[:cntrl:]]/} (expected 1-10 characters: a lowercase letter, then lowercase letters, digits, or inner hyphens)" >&2
      return 1
    fi
    if [[ "$seen" == *" $token "* ]]; then
      echo "Duplicate site slug: ${token//[[:cntrl:]]/}" >&2
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

# Print the environment-name fragment for a slug: every hyphen becomes an
# underscore. Bash indirect expansion cannot resolve names containing hyphens,
# and slugs never contain underscores, so this mapping is unique.
_slug_suffix() {
  printf '%s' "${1//-/_}"
}

# Print the value of the first nonempty environment variable for a
# (slug,target) pair, trying:
#   <base>_<slug_suffix>_<target>
#   <base>_<slug_suffix>  when exactly one target is selected
#   <base>_<target>       when exactly one slug is selected
#   <base>                when exactly one slug and one target are selected
_site_value() {
  local base="$1" slug="$2" target="$3" slug_total="$4" target_total="$5"
  local suffix name value
  suffix="$(_slug_suffix "$slug")"
  name="${base}_${suffix}_${target}"
  value="${!name-}"
  if [[ -z "$value" && "$target_total" == 1 ]]; then
    name="${base}_${suffix}"
    value="${!name-}"
  fi
  if [[ -z "$value" && "$slug_total" == 1 ]]; then
    name="${base}_${target}"
    value="${!name-}"
  fi
  if [[ -z "$value" && "$slug_total" == 1 && "$target_total" == 1 ]]; then
    name="$base"
    value="${!name-}"
  fi
  printf '%s' "$value"
}

# Print 1 when the value is one of the accepted true spellings (1, true,
# yes), otherwise 0. Every boolean operator variable is normalized through
# this so the payload only ever sees 0 and 1.
_normalize_bool() {
  case "${1:-}" in
  1 | true | yes) printf '1\n' ;;
  *) printf '0\n' ;;
  esac
}

# Print the validated site slug list selected for a target, one per line.
# Resolution order: the explicit per-target override var_sites_<target>, then
# the global explicit var_sites, then the plan the interactive label editor
# stored for this target in TARGET_SLUG_PLANS, then `default`.
_sites_for_target() {
  local target="${1:-host}" name="var_sites_${1:-host}" raw i
  raw="${!name-}"
  if [[ -z "$raw" ]]; then
    raw="${var_sites:-}"
  fi
  if [[ -z "$raw" ]]; then
    for ((i = 0; i < ${#TARGETS[@]}; i++)); do
      if [[ "${TARGETS[i]}" == "$target" ]] && [[ -n "${TARGET_SLUG_PLANS[i]:-}" ]]; then
        raw="${TARGET_SLUG_PLANS[i]}"
      fi
    done
  fi
  if [[ -z "$raw" ]]; then
    raw="default"
  fi
  _parse_sites "$raw"
}

# Set SLUG_LIST (newline list), SLUG_ARRAY, SLUG_TOTAL, and SLUG_MULTI for a
# target. SLUG_MULTI is 1 when the list holds more than one slug, any
# non-default slug, or an explicit var_multi_sites request.
_resolve_target_slug_plan() {
  local target="${1:-host}" slug
  SLUG_LIST="$(_sites_for_target "$target")" || return 1
  mapfile -t SLUG_ARRAY <<<"$SLUG_LIST"
  SLUG_TOTAL=${#SLUG_ARRAY[@]}
  SLUG_MULTI=0
  if ((SLUG_TOTAL > 1)); then
    SLUG_MULTI=1
  fi
  for slug in "${SLUG_ARRAY[@]}"; do
    if [[ "$slug" != default ]]; then
      SLUG_MULTI=1
    fi
  done
  if [[ "$(_normalize_bool "${var_multi_sites:-}")" == 1 ]]; then
    SLUG_MULTI=1
  fi
}

# Print the default native interface name for a validated slug. The prefixes
# make Pangolin ownership explicit; with the 10-character slug cap the names
# never exceed Linux IFNAMSIZ (15 characters). These pure generators live in
# the entry so pre-payload validation and the dry run can name the interfaces
# before any payload is fetched or sourced.
default_site_interface() {
  printf 'pang%s' "$1"
}

# Print the default native main-tunnel interface name for a validated slug.
default_site_interface_main() {
  printf 'pangm%s' "$1"
}

# Print the site SSH owner effective for a target's newline-delimited slug
# list. var_site_ssh_owner wins; `default` (the default value) falls back to
# the first selected slug when the list holds no `default` entry, because the
# embedded SSH daemon must belong to one of the installed instances.
_site_ssh_owner() {
  local slugs="${1:-}" owner="${var_site_ssh_owner-}" first="" line
  if [[ -z "$owner" ]]; then
    owner=default
  fi
  if [[ "$owner" == default ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ -z "$first" ]]; then
        first="$line"
      fi
      if [[ "$line" == default ]]; then
        first=default
        break
      fi
    done <<<"$slugs"
    if [[ "$first" != default ]]; then
      owner="$first"
    fi
  fi
  printf '%s\n' "$owner"
}

# Print the endpoint for a (slug,target) pair: the resolved slug/target form,
# then the shared var_pangolin_endpoint, which the operator is prompted for
# once per run.
_site_pair_endpoint() {
  local value
  value="$(_site_value var_pangolin_endpoint "$1" "$2" "$3" "$4")"
  if [[ -z "$value" ]]; then
    value="${var_pangolin_endpoint:-}"
  fi
  printf '%s' "$value"
}

# Print the interface name for a (slug,target) pair. `kind` is client or
# main. Resolution order: var_site_interface[_main]_<slug>_<target>, then
# <slug> (single target), then <target> (single slug), then the operator-set
# shared variable, then the generated per-slug default. The shared variable
# is read from the raw environment captured before main() applies its
# `pangolin` default (SITE_INTERFACE_CAPTURED), so the single-site default
# name never leaks into per-slug resolution and collide across slugs.
_site_pair_interface() {
  local slug="$1" target="$2" st="$3" tt="$4" kind="$5"
  local base suffix name value
  if [[ "$kind" == main ]]; then
    base="var_site_interface_main"
  else
    base="var_site_interface"
  fi
  suffix="$(_slug_suffix "$slug")"
  value=""
  name="${base}_${suffix}_${target}"
  value="${!name-}"
  if [[ -z "$value" && "$tt" == 1 ]]; then
    name="${base}_${suffix}"
    value="${!name-}"
  fi
  if [[ -z "$value" && "$st" == 1 ]]; then
    name="${base}_${target}"
    value="${!name-}"
  fi
  if [[ -z "$value" ]]; then
    if [[ "${SITE_INTERFACE_CAPTURED:-0}" == 1 ]]; then
      if [[ "$kind" == main ]]; then
        value="${SITE_INTERFACE_MAIN_RAW:-}"
      else
        value="${SITE_INTERFACE_RAW:-}"
      fi
    else
      value="${!base-}"
    fi
  fi
  if [[ -z "$value" ]]; then
    if [[ "$kind" == main ]]; then
      value="$(default_site_interface_main "$slug")"
    else
      value="$(default_site_interface "$slug")"
    fi
  fi
  printf '%s' "$value"
}

# Print the effective interface names for every enabled native mode across a
# slug list, one per line, for one target. Arguments: target, slug total,
# target total, then the slugs. Empty names are never emitted, so the output
# is safe to hand to validate_interface_names_on_target, which rejects blank
# entries; with no enabled native mode the output is empty and the caller
# skips the check entirely.
_collect_site_interfaces() {
  local target="${1:-host}" st="${2:-1}" tt="${3:-1}"
  shift 3
  local slug iface
  local -a names=()
  for slug in "$@"; do
    if [[ "${var_site_native-0}" == 1 ]]; then
      iface="$(_site_pair_interface "$slug" "$target" "$st" "$tt" client)"
      if [[ -n "$iface" ]]; then
        names+=("$iface")
      fi
    fi
    if [[ "${var_site_native_main-0}" == 1 ]]; then
      iface="$(_site_pair_interface "$slug" "$target" "$st" "$tt" main)"
      if [[ -n "$iface" ]]; then
        names+=("$iface")
      fi
    fi
  done
  if ((${#names[@]} == 0)); then
    return 0
  fi
  printf '%s\n' "${names[@]}"
}

# Save the site credential globals for the (slug,target) pair just resolved.
_store_site_pair() {
  local slug="$1" target="$2" key="$1|$2"
  SITE_PAIR_ID[$key]="${var_site_id-}"
  SITE_PAIR_SECRET[$key]="${var_site_secret-}"
  SITE_PAIR_KEY[$key]="${var_site_provisioning_key-}"
  SITE_PAIR_NAME[$key]="${var_site_name-}"
}

# Fill the site credential globals for one (slug,target) pair: interactively
# stored values first, then the environment through the _site_value
# precedence. Arguments: slug, target, slug total, target total.
_activate_site_pair() {
  local slug="$1" target="$2" st="$3" tt="$4" key="$1|$2" value
  value="${SITE_PAIR_ID[$key]-}"
  if [[ -z "$value" ]]; then
    value="$(_site_value var_site_id "$slug" "$target" "$st" "$tt")"
  fi
  var_site_id="$value"
  value="${SITE_PAIR_SECRET[$key]-}"
  if [[ -z "$value" ]]; then
    value="$(_site_value var_site_secret "$slug" "$target" "$st" "$tt")"
  fi
  var_site_secret="$value"
  value="${SITE_PAIR_KEY[$key]-}"
  if [[ -z "$value" ]]; then
    value="$(_site_value var_site_provisioning_key "$slug" "$target" "$st" "$tt")"
  fi
  var_site_provisioning_key="$value"
  value="${SITE_PAIR_NAME[$key]-}"
  if [[ -z "$value" ]]; then
    value="$(_site_value var_site_name "$slug" "$target" "$st" "$tt")"
  fi
  var_site_name="$value"
}

# Print the default provisioning site name for a multi-site (slug,target)
# pair: <hostname>-<slug> with one target, <hostname>-<slug>-<target> with
# several. The legacy single-site path keeps the plain hostname default.
_default_provisioning_site_name() {
  local target="$1" slug="$2" host
  host="$(_default_site_name "$target")"
  if ((${#TARGETS[@]} > 1)); then
    printf '%s-%s-%s\n' "$host" "$slug" "$target"
  else
    printf '%s-%s\n' "$host" "$slug"
  fi
}

# Print the target's site layout state: single, template, or mixed. Read-only
# in both branches: the host uses the payload's file inspection, an LXC uses
# one sh -c probe that only reads files.
_target_site_layout() {
  local target="${1:-host}" out=""
  if [[ "$target" == host ]]; then
    if declare -F site_conversion_state >/dev/null 2>&1; then
      out="$(site_conversion_state 2>/dev/null)" || out=""
    fi
  elif command -v pct >/dev/null 2>&1; then
    out="$(pct exec "$target" -- sh -c '
t=0; l=0
v=$(head -n 1 /var/lib/pangolin/site-layout 2>/dev/null)
[ "$v" = template ] && t=1
[ -e /etc/systemd/system/pangolin-site@.service ] && t=1
for f in /etc/init.d/pangolin-site-*; do
  case "$f" in (*"*"*) continue ;; esac
  if [ -e "$f" ] || [ -L "$f" ]; then t=1; fi
done
for f in /etc/systemd/system/pangolin-site.service \
  /etc/systemd/system/multi-user.target.wants/pangolin-site.service \
  /etc/init.d/pangolin-site /etc/runlevels/default/pangolin-site; do
  if [ -e "$f" ] || [ -L "$f" ]; then l=1; fi
done
if [ "$t" = 1 ] && [ "$l" = 1 ]; then echo mixed
elif [ "$t" = 1 ]; then echo template
else echo single
fi' 2>/dev/null)" || out=""
  fi
  case "$out" in
  template | mixed) printf '%s\n' "$out" ;;
  *) printf 'single\n' ;;
  esac
}

# Succeed when the target already holds a per-slug site configuration. The
# slug is validated before it is used in a path or in a remote command, and
# the probe is read-only.
_target_site_slug_exists() {
  local target="${1:-}" slug="${2:-}" path
  validate_site_slug "$slug" || return 1
  if [[ "$target" == host ]]; then
    if declare -F site_config_path >/dev/null 2>&1; then
      path="$(site_config_path "$slug" 2>/dev/null)" || return 1
    else
      path="/etc/pangolin/sites/$slug.json"
    fi
    [[ -f "$path" ]]
    return
  fi
  pct exec "$target" -- sh -c "test -f /etc/pangolin/sites/$slug.json" >/dev/null 2>&1
}

# Succeed when the target already holds a reusable site configuration for a
# slug: the per-slug file exists and carries either an id and secret or a
# provisioning key, so the payload can serve the slug without new answers.
# A missing or malformed file is not reusable. The slug is validated before
# it is used in a path or a remote command, the probe is read-only, and no
# config content leaves the target.
_target_site_slug_reusable() {
  local target="${1:-}" slug="${2:-}" path
  validate_site_slug "$slug" || return 1
  if [[ "$target" == host ]]; then
    if declare -F site_config_path >/dev/null 2>&1; then
      path="$(site_config_path "$slug" 2>/dev/null)" || return 1
    else
      path="/etc/pangolin/sites/$slug.json"
    fi
    [[ -f "$path" ]] || return 1
    if grep -q '"provisioningKey"[[:space:]]*:' "$path"; then
      return 0
    fi
    grep -q '"id"[[:space:]]*:' "$path" &&
      grep -q '"secret"[[:space:]]*:' "$path"
    return
  fi
  pct exec "$target" -- sh -c \
    "grep -q '\"provisioningKey\"[[:space:]]*:' /etc/pangolin/sites/$slug.json 2>/dev/null || { grep -q '\"id\"[[:space:]]*:' /etc/pangolin/sites/$slug.json 2>/dev/null && grep -q '\"secret\"[[:space:]]*:' /etc/pangolin/sites/$slug.json 2>/dev/null; }" \
    >/dev/null 2>&1
}

# Remember a static site ID for this run and reject a duplicate before the
# affected target is mutated. IDs are identifiers, never secrets.
_remember_site_id() {
  local id="${1:-}"
  [[ -n "$id" ]] || return 0
  if [[ "$SEEN_SITE_IDS" == *$'\n'"$id"$'\n'* ]]; then
    echo "Duplicate site ID: $id (each site ID may be used only once per run)" >&2
    return 1
  fi
  SEEN_SITE_IDS+="$id"$'\n'
}

# Remember a machine client ID for this run and reject a duplicate before the
# affected target is mutated.
_remember_client_id() {
  local id="${1:-}"
  [[ -n "$id" ]] || return 0
  if [[ "$SEEN_CLIENT_IDS" == *$'\n'"$id"$'\n'* ]]; then
    echo "Duplicate client ID: $id (each client ID may be used only once per run)" >&2
    return 1
  fi
  SEEN_CLIENT_IDS+="$id"$'\n'
}

# Validate the whole site plan before any target is touched: every slug list,
# the SSH owner against each list, the interface overrides (format and
# uniqueness per target), and the static site IDs resolvable from the
# environment. A dry run additionally requires credentials for every
# non-default slug, because it may not probe a target.
_validate_site_plan() {
  local dry="${1:-0}"
  local i target owner slug names value st tt
  local all_ids=""
  tt=${#TARGETS[@]}
  for ((i = 0; i < tt; i++)); do
    target="${TARGETS[i]}"
    _resolve_target_slug_plan "$target" || return 1
    TARGET_SLUGS[i]="${SLUG_ARRAY[*]}"
    TARGET_MULTI[i]="$SLUG_MULTI"
    st="$SLUG_TOTAL"
    owner="$(_site_ssh_owner "$SLUG_LIST")"
    validate_site_ssh_owner "$owner" "$SLUG_LIST" || return 1
    names="$(_collect_site_interfaces "$target" "$st" "$tt" "${SLUG_ARRAY[@]}")"
    if [[ -n "$names" ]]; then
      while IFS= read -r value; do
        if [[ -n "$value" ]] && ! validate_interface_name "$value"; then
          echo "Invalid native interface name: ${value//[[:cntrl:]]/} (expected 1-15 characters, starting with a letter, using letters, digits, _, -, or .)" >&2
          return 1
        fi
      done <<<"$names"
      interface_names_unique "$names" || return 1
    fi
    for slug in "${SLUG_ARRAY[@]}"; do
      value="$(_site_value var_site_provisioning_key "$slug" "$target" "$st" "$tt")"
      if [[ -z "$value" ]]; then
        local id secret endpoint
        id="$(_site_value var_site_id "$slug" "$target" "$st" "$tt")"
        secret="$(_site_value var_site_secret "$slug" "$target" "$st" "$tt")"
        if [[ -n "$id" && -z "$secret" ]] || [[ -z "$id" && -n "$secret" ]]; then
          echo "Site credentials for $slug on $target are incomplete; provide var_site_id and var_site_secret together." >&2
          return 1
        fi
        if [[ -n "$id" ]]; then
          all_ids+="$id"$'\n'
        elif [[ "$slug" != default && "$dry" == 1 ]]; then
          echo "Site $slug needs a provisioning key or a site ID and secret." >&2
          return 1
        fi
      fi
      endpoint="$(_site_pair_endpoint "$slug" "$target" "$st" "$tt")"
      if [[ -n "$endpoint" ]] && ! validate_endpoint "$endpoint"; then
        echo "Invalid Pangolin endpoint for site $slug on $target; expected an http(s) URL with a host." >&2
        return 1
      fi
    done
  done
  if [[ -n "$all_ids" ]]; then
    validate_unique_site_ids "${all_ids%$'\n'}" || return 1
  fi
}

# Reject a machine client ID used by two targets before any target is touched.
_validate_client_plan() {
  local i ids=""
  for ((i = 0; i < ${#TARGETS[@]}; i++)); do
    if [[ -n "${TARGET_CLIENT_ID[i]-}" ]]; then
      ids+="${TARGET_CLIENT_ID[i]}"$'\n'
    fi
  done
  if [[ -n "$ids" ]]; then
    validate_unique_client_ids "${ids%$'\n'}" || return 1
  fi
}

# Succeed when every nonempty line appears at most once. The label names the
# ID kind in the error; IDs are identifiers, never secrets.
_check_unique_ids() {
  local label="$1" ids="${2:-}" line seen=$'\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$seen" == *$'\n'"$line"$'\n'* ]]; then
      echo "Duplicate $label ID: $line (each $label ID may be used only once per run)" >&2
      return 1
    fi
    seen+="$line"$'\n'
  done <<<"$ids"
}

# Succeed when no static site ID repeats across the selected (slug,target)
# pairs; a static site ID is single-use.
validate_unique_site_ids() {
  _check_unique_ids site "${1:-}"
}

# Succeed when no machine-client ID repeats across the selected targets.
validate_unique_client_ids() {
  _check_unique_ids client "${1:-}"
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
# The multi-site arguments list the resolved slugs and the slug-based
# multi-site decision; the dry run never probes a target layout, so a single
# default slug shows the legacy plan with a conversion note.
_print_dry_run() {
  local mode="$1" target="$2" site="$3" client="$4" reconfigure="$5"
  local slugs="${6:-default}" multi="${7:-0}"
  local where="host" prefix="" site_native=0 site_native_main=0 need_tun=0
  local native_label="disabled" main_label="disabled" dslug dip
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
    printf 'Sites: %s\n' "$slugs"
    printf 'SSH owner: %s\n' "$(_site_ssh_owner "${slugs// /$'\n'}")"
    if [[ "$multi" == 1 ]]; then
      printf 'Site layout: per-slug site instances (multi-site)\n'
    else
      printf 'Site layout: single-site; an already-converted target uses the per-slug path\n'
    fi
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
    if [[ "$multi" == 1 ]]; then
      printf '  - Site native client tunnels: %s\n' "$native_label"
      printf '  - Site native main tunnel: %s\n' "$main_label"
    else
      printf '  - Site native client tunnels: %s (interface %s)\n' \
        "$native_label" "${var_site_interface-pangolin}"
      printf '  - Site native main tunnel: %s (interface %s)\n' \
        "$main_label" "${var_site_interface_main-pangolin}"
    fi
    if [[ "$multi" == 1 ]]; then
      local -a darr=($slugs)
      local dst="${#darr[@]}" dtt="${#TARGETS[@]}"
      for dslug in "${darr[@]}"; do
        if [[ "$site_native" == 1 ]]; then
          dip="$(_site_pair_interface "$dslug" "$target" "$dst" "$dtt" client)"
          printf '  - Site %s native client interface: %s\n' "$dslug" "$dip"
        fi
        if [[ "$site_native_main" == 1 ]]; then
          dip="$(_site_pair_interface "$dslug" "$target" "$dst" "$dtt" main)"
          printf '  - Site %s native main interface: %s\n' "$dslug" "$dip"
        fi
      done
    fi
    if [[ "$reconfigure" != 1 ]] && ! _has_site_form && [[ "$multi" != 1 ]] &&
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

# Run the shared site native checklist once per run and set the toggles.
# Only a completed checklist is shared; a cancel leaves it unasked for the
# next target, exactly as before.
_prompt_site_native_checklist() {
  local net_choice net_state="OFF" main_state="OFF"
  if [[ "${NATIVE_PROMPTED:-0}" == 1 ]]; then
    return 0
  fi
  if [[ "${var_site_native-0}" == 1 ]]; then
    net_state="ON"
  fi
  if [[ "${var_site_native_main-0}" == 1 ]]; then
    main_state="ON"
  fi
  net_choice="$(whiptail --title "Site networking" --checklist \
    "Site networking:" 15 74 2 \
    main "native main tunnel (kernel interface, needs TUN)" "$main_state" \
    client "native client tunnels (kernel interface, needs TUN)" "$net_state" \
    3>&1 1>&2 2>&3)" || return 1
  NATIVE_PROMPTED=1
  var_site_native=0
  var_site_native_main=0
  case "$net_choice" in
  *'"client"'*) var_site_native=1 ;;
  esac
  case "$net_choice" in
  *'"main"'*) var_site_native_main=1 ;;
  esac
}

# Print the site labels that already have a configuration on the target: one
# slug per line, deduplicated, `default` first, malformed names ignored. The
# host globs the payload's site directory under the private root; an LXC is
# probed with read-only pct calls that never interpolate a caller-supplied
# slug. Config contents are never read or printed. `default` answers for a
# legacy site.json, a legacy site env, and for any target where discovery
# finds nothing, so at least one label is always available.
_discover_site_slugs() {
  local target="${1:-host}" entry slug dir sitejson
  local -a names=() others=()
  local has_default=0 found=0 seen=$'\n' out=""
  if [[ "$target" == host ]]; then
    if declare -F site_config_dir >/dev/null 2>&1; then
      dir="$(site_config_dir)"
      sitejson="$(p /etc/pangolin/site.json)"
    else
      dir="/etc/pangolin/sites"
      sitejson="/etc/pangolin/site.json"
    fi
    shopt -s nullglob
    for entry in "$dir"/*.json; do
      names+=("${entry##*/}")
    done
    shopt -u nullglob
    [[ -f "$sitejson" ]] && has_default=1
  else
    while IFS= read -r entry; do
      if [[ -n "$entry" ]]; then
        names+=("$entry")
      fi
    done < <(pct exec "$target" -- ls -1 /etc/pangolin/sites 2>/dev/null || true)
    if pct exec "$target" -- sh -c \
      'test -f /etc/pangolin/site.json' >/dev/null 2>&1; then
      has_default=1
    fi
  fi
  if _target_has_legacy_site "$target"; then
    has_default=1
  fi
  for entry in "${names[@]}"; do
    [[ "$entry" == *.json ]] || continue
    slug="${entry%.json}"
    validate_site_slug "$slug" || continue
    found=1
    if [[ "$slug" == default ]]; then
      has_default=1
    elif [[ "$seen" != *$'\n'"$slug"$'\n'* ]]; then
      seen+="$slug"$'\n'
      others+=("$slug")
    fi
  done
  if ((found == 0)); then
    has_default=1
  fi
  if ((has_default == 1)); then
    out+=$'default\n'
  fi
  for slug in "${others[@]}"; do
    out+="$slug"$'\n'
  done
  printf '%s' "$out"
}

# Run the interactive site label editor for one target and set
# SITE_LABEL_PLAN to the selected space-separated list. The editor seeds
# every label that already has a configuration on the target, all starting
# selected, so an existing site is never left out of the plan; the operator
# can only add labels. Returns 1 on cancel or an empty selection.
_prompt_site_labels() {
  local target="${1:-host}"
  local -a slugs=()
  local out item new label s dup slug
  while IFS= read -r slug; do
    if [[ -n "$slug" ]]; then
      slugs+=("$slug")
    fi
  done < <(_discover_site_slugs "$target")
  if ((${#slugs[@]} == 0)); then
    slugs=(default)
  fi
  local -a selected kept
  while :; do
    local -a rows=()
    for s in "${slugs[@]}"; do
      rows+=("$s" "Site label $s" "ON")
    done
    rows+=("add" "Add another site label" "OFF" "done" "Use these site labels" "OFF")
    out="$(whiptail --title "Site labels" --checklist \
      "Manage site labels (space toggles, up to 8):" 20 74 8 "${rows[@]}" 3>&1 1>&2 2>&3)" ||
      return 1
    out="${out//\"/}"
    _split_words selected "$out"
    kept=()
    new=""
    for item in "${selected[@]}"; do
      case "$item" in
      add) new=add ;;
      done) ;;
      *) kept+=("$item") ;;
      esac
    done
    if [[ "$new" == add ]]; then
      if ((${#kept[@]} >= 8)); then
        msg_warn "Eight site labels is the maximum." >&2
      else
        label="$(_prompt_value "New site label" "New site label" "" 0)" || return 1
        if ! validate_site_slug "$label"; then
          msg_warn "Invalid site label. Use 1-10 characters: a lowercase letter, then lowercase letters, digits, or inner hyphens." >&2
        else
          dup=0
          for s in "${kept[@]}"; do
            if [[ "$s" == "$label" ]]; then
              dup=1
            fi
          done
          if ((dup == 0)); then
            kept+=("$label")
          else
            msg_warn "Site label $label is already selected." >&2
          fi
        fi
      fi
      slugs=("${kept[@]}")
      continue
    fi
    if ((${#kept[@]} == 0)); then
      echo "Select at least one site label" >&2
      return 1
    fi
    if ((${#kept[@]} > 8)); then
      msg_warn "Eight site labels is the maximum. Deselect labels to continue." >&2
      slugs=("${kept[@]}")
      continue
    fi
    _parse_sites "${kept[*]}" >/dev/null || return 1
    SITE_LABEL_PLAN="${kept[*]}"
    return 0
  done
}

# Ask the shared site SSH owner once: one of the selected slugs, or none.
_prompt_site_ssh_owner() {
  local slugs="${1:-}" choice s
  local -a rows=()
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    rows+=("$s" "Embedded SSH daemon stays with $s")
  done <<<"$slugs"
  rows+=("none" "No site keeps the embedded SSH daemon")
  choice="$(whiptail --title "Pangolin Addon" --menu \
    "Site SSH owner:" 20 74 8 "${rows[@]}" 3>&1 1>&2 2>&3)" || return 1
  var_site_ssh_owner="$choice"
  SITE_OWNER_PROMPTED=1
}

# Resolve and prompt the site credentials for one (slug,target) pair. The
# globals are already activated for the pair: a complete form is stored as-is
# so prompts reuse existing values where valid, and only an incomplete pair
# is asked about.
_prompt_site_pair_credentials() {
  local target="$1" slug="$2" choice
  if [[ -n "${var_site_provisioning_key:-}" ]]; then
    if [[ -z "${var_site_name:-}" ]]; then
      var_site_name="$(_default_provisioning_site_name "$target" "$slug")"
    fi
    _store_site_pair "$slug" "$target"
    return 0
  fi
  if [[ -n "${var_site_id:-}" && -n "${var_site_secret:-}" ]]; then
    _store_site_pair "$slug" "$target"
    return 0
  fi
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
      var_site_name="$(_prompt_value "Site name" "Site name" \
        "$(_default_provisioning_site_name "$target" "$slug")" 0)" || return 1
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
  _store_site_pair "$slug" "$target"
}

# Collect interactive credentials. Existing verified site configs are offered
# as reuse or replace once the operator chooses the one-site path; client
# credentials are always prompted when missing. A site enrollment ends with
# the native interface toggles; names are never prompted. In a site
# enrollment with no explicit var_sites every target first chooses one site
# or manages several site labels, even when a verified existing site is
# detected, so an extra slug can always be added to the existing site; the
# editor's answer is stored for that target alone, never in the global
# var_sites. A multi-site selection then asks for the SSH owner, the shared
# native toggles, and the credentials of every slug/target pair the
# environment does not answer and the target cannot serve: a pair whose
# existing config already holds credentials or a provisioning key is reused
# as it is.
_prompt_inputs() {
  local target="$1" site="$2" client="$3" choice default_name
  local enrolling=0
  if [[ "$site" == 1 ]]; then
    local explicit=0 sited_var="var_sites_${target}"
    if [[ -n "${var_sites:-}" || -n "${!sited_var:-}" ]]; then
      explicit=1
    fi
    local may_reuse=0
    if [[ "${var_reconfigure:-0}" != 1 ]] && _target_site_verified "$target"; then
      may_reuse=1
    fi
    if ((explicit == 0)) && ! _is_noninteractive; then
      choice="$(whiptail --title "Pangolin Addon" --menu \
        "Configure one site or manage multiple site labels:" 15 74 2 \
        one "One site (the default label)" \
        multi "Manage multiple site labels" 3>&1 1>&2 2>&3)" || return 1
      if [[ "$choice" == multi ]]; then
        _prompt_site_labels "$target" || return 1
        local plan_idx=-1 pi
        for ((pi = 0; pi < ${#TARGETS[@]}; pi++)); do
          if [[ "${TARGETS[pi]}" == "$target" ]]; then
            plan_idx=$pi
          fi
        done
        if ((plan_idx < 0)); then
          echo "Target $target is not part of this run; cannot store its site label plan." >&2
          return 1
        fi
        TARGET_SLUG_PLANS[plan_idx]="$SITE_LABEL_PLAN"
      fi
    fi
    _resolve_target_slug_plan "$target" || return 1
    if [[ "$SLUG_MULTI" == 1 ]]; then
      if [[ -z "${var_pangolin_endpoint:-}" ]]; then
        var_pangolin_endpoint="$(whiptail --title "Pangolin Addon" \
          --inputbox "Pangolin endpoint" 10 64 "https://app.pangolin.net" 3>&1 1>&2 2>&3)" ||
          return 1
      fi
      if [[ -z "${var_site_ssh_owner:-}" && "$SITE_OWNER_PROMPTED" != 1 ]]; then
        _prompt_site_ssh_owner "$SLUG_LIST" || return 1
      fi
      _prompt_site_native_checklist || return 1
      local mslug mitra pair_found
      for mslug in "${SLUG_ARRAY[@]}"; do
        if [[ "${var_site_native:-0}" == 1 ]]; then
          mitra="$(_site_pair_interface "$mslug" "$target" "$SLUG_TOTAL" "${#TARGETS[@]}" client)"
          printf 'Site %s native client interface: %s\n' "$mslug" "$mitra"
        fi
        if [[ "${var_site_native_main:-0}" == 1 ]]; then
          mitra="$(_site_pair_interface "$mslug" "$target" "$SLUG_TOTAL" "${#TARGETS[@]}" main)"
          printf 'Site %s native main interface: %s\n' "$mslug" "$mitra"
        fi
      done
      for mslug in "${SLUG_ARRAY[@]}"; do
        _activate_site_pair "$mslug" "$target" "$SLUG_TOTAL" "${#TARGETS[@]}"
        pair_found=0
        if [[ -n "${var_site_provisioning_key:-}" ]]; then
          pair_found=1
          _store_site_pair "$mslug" "$target"
        elif [[ -n "${var_site_id:-}" && -n "${var_site_secret:-}" ]]; then
          pair_found=1
          _store_site_pair "$mslug" "$target"
        fi
        if ((pair_found == 0)) && [[ "${var_reconfigure:-0}" != 1 ]]; then
          if [[ "$mslug" == default ]]; then
            if _target_site_verified "$target" || _target_has_legacy_site "$target" ||
              _target_site_slug_exists "$target" "$mslug"; then
              continue
            fi
          elif _target_site_slug_reusable "$target" "$mslug"; then
            continue
          fi
        fi
        if ((pair_found == 0)); then
          _prompt_site_pair_credentials "$target" "$mslug" || return 1
        fi
      done
    elif [[ "$may_reuse" == 1 ]]; then
      choice="$(whiptail --title "Existing site" --menu \
        "A verified site configuration already exists." 15 64 2 \
        reuse "Reuse the existing site configuration" \
        replace "Replace it with new credentials" 3>&1 1>&2 2>&3)" || return 1
      if [[ "$choice" == replace ]]; then
        var_reconfigure=1
      fi
    fi
    if [[ "$SLUG_MULTI" != 1 ]] &&
      { [[ "${var_reconfigure:-0}" == 1 ]] || ! _target_site_verified "$target"; }; then
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
        # Store the entered default credentials as per-pair state so a target
        # that the layout probe later switches to the per-slug path (an
        # already-converted host) still finds them; _activate_site_pair reads
        # this before the environment, where unsuffixed globals would be
        # ignored.
        _store_site_pair default "$target"
      fi
    elif [[ "$SLUG_MULTI" != 1 ]] && [[ "$may_reuse" == 1 ]] && _has_site_form; then
      msg_warn "Ignoring new site credentials; the verified site configuration is reused. Set var_reconfigure=1 to replace it."
    fi
    if [[ "$SLUG_MULTI" != 1 ]] && [[ "$enrolling" == 1 ]]; then
      _prompt_site_native_checklist || return 1
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

# Validate the multi-site plan for one target before any change: the SSH
# owner, the interface names (format, uniqueness, and existence on the
# target, which runs after the container is started and before any TUN
# change or payload run), the static site IDs, and the credential
# completeness of every requested slug. A pair with no credentials is
# allowed only when the target already holds a config that can serve it.
_prepare_multi_site_target() {
  local target="$1" reconfigure="$2"
  local st="$SLUG_TOTAL" tt="${#TARGETS[@]}" slug owner
  local names value ekey eid esec
  owner="$(_site_ssh_owner "$SLUG_LIST")"
  validate_site_ssh_owner "$owner" "$SLUG_LIST" || return 1
  names="$(_collect_site_interfaces "$target" "$st" "$tt" "${SLUG_ARRAY[@]}")"
  if [[ -n "$names" ]]; then
    while IFS= read -r value; do
      if [[ -n "$value" ]] && ! validate_interface_name "$value"; then
        echo "Invalid native interface name: ${value//[[:cntrl:]]/} (expected 1-15 characters, starting with a letter, using letters, digits, _, -, or .)" >&2
        return 1
      fi
    done <<<"$names"
    interface_names_unique "$names" || return 1
    validate_interface_names_on_target "$target" "$names" || return 1
  fi
  for slug in "${SLUG_ARRAY[@]}"; do
    _activate_site_pair "$slug" "$target" "$st" "$tt"
    ekey="${var_site_provisioning_key:-}"
    eid="${var_site_id:-}"
    esec="${var_site_secret:-}"
    if [[ -n "$eid" ]] && [[ -z "$esec" ]] || [[ -z "$eid" ]] && [[ -n "$esec" ]]; then
      echo "Site credentials for $slug on $target are incomplete; provide var_site_id and var_site_secret together." >&2
      return 1
    fi
    if [[ -n "$eid" ]] && ! _remember_site_id "$eid"; then
      return 1
    fi
    if [[ -z "$ekey" && -z "$eid" && -z "$esec" ]]; then
      if [[ "$reconfigure" == 1 && "$slug" == default ]]; then
        echo "Site default needs a provisioning key or a site ID and secret when reconfiguring." >&2
        return 1
      fi
      if _target_site_slug_exists "$target" "$slug"; then
        continue
      fi
      if [[ "$slug" == default ]]; then
        if _target_site_verified "$target" || _target_has_legacy_site "$target"; then
          continue
        fi
        msg_error "No site configuration found. Provide a provisioning key or a site ID and secret."
        return 1
      fi
      echo "Site $slug needs a provisioning key or a site ID and secret." >&2
      return 1
    fi
  done
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
# Multi-site runs pass the verified slug list and the payload's backend so
# the commands name the real instance unit.
_print_next_steps() {
  local target="$1" site="$2" client="$3" slugs="${4:-default}" backend="${5:-single}"
  local prefix="" nslug
  if [[ "$target" != host ]]; then
    prefix="pct exec $target -- "
  fi
  if [[ "$site" == 1 ]]; then
    msg_ok "Pangolin site is installed."
    case "$backend" in
    systemd)
      for nslug in $slugs; do
        printf '  %ssystemctl status pangolin-site@%s\n' "$prefix" "$nslug"
        printf '  %sjournalctl -u pangolin-site@%s\n' "$prefix" "$nslug"
      done
      ;;
    openrc)
      for nslug in $slugs; do
        printf '  %src-service pangolin-site-%s status\n' "$prefix" "$nslug"
        printf '  %s/var/log/pangolin-site-%s.log\n' "$prefix" "$nslug"
      done
      ;;
    *)
      printf '  %spangolin service status site\n' "$prefix"
      printf '  %spangolin service logs site\n' "$prefix"
      ;;
    esac
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
# the components that actually verified. Sets VERIFIED_SITE/VERIFIED_CLIENT,
# the verified slug list, and the backend. site:<slug> markers count as the
# site component, so any verified slug still maps to the one pangolin-site
# tag.
_apply_verified_tags() {
  local target="$1" answers="$2" content="" line
  VERIFIED_SITE=0
  VERIFIED_CLIENT=0
  VERIFIED_SLUGS=""
  VERIFIED_BACKEND="single"
  if [[ "$target" == host ]]; then
    content="$(cat "$answers/verified" 2>/dev/null || true)"
  else
    content="$(pct exec "$target" -- cat /root/.pangolin-addon/verified 2>/dev/null || true)"
  fi
  while IFS= read -r line; do
    case "$line" in
    site) VERIFIED_SITE=1 ;;
    site:*)
      VERIFIED_SITE=1
      VERIFIED_SLUGS+="${line#site:} "
      ;;
    client) VERIFIED_CLIENT=1 ;;
    backend:*) VERIFIED_BACKEND="${line#backend:}" ;;
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
  # A stale verified marker from an earlier run must never tag this target.
  _remove_remote_answers "$target"
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

# Print the result of every target after the loop, and for a multi-site
# target the per-slug verification status. No credentials are printed.
_print_run_summary() {
  local i
  printf '\nPangolin addon summary\n'
  for ((i = 0; i < ${#TARGETS[@]}; i++)); do
    printf '  %s: %s\n' "${TARGETS[i]}" "${TARGET_STATUS[i]:-failed}"
    if [[ -n "${TARGET_SLUG_STATUS[i]:-}" ]]; then
      printf '%s\n' "${TARGET_SLUG_STATUS[i]}"
    fi
  done
}

# Install one target from the shared selections. Returns non-zero for that
# target only; the caller continues with the rest. Credentials for the target
# come from the per-target arrays, except in interactive mode where the prompts
# fill them for this target. A multi-site target resolves its credentials per
# (slug,target) pair, and one convert_site_layout call in the payload installs
# every requested slug.
_install_target() {
  local target="$1" index="$2" site="$3" client="$4" shared_reconfigure="$5"
  local reconfigure="${TARGET_RECONFIGURE[index]:-$shared_reconfigure}"
  local site_answers=0 need_tun=0 payload_rc=0 name="" answers=""
  local multi=0 st=1 tt="${#TARGETS[@]}" ep disable_ssh
  local prov_warned=0

  if _is_noninteractive; then
    _activate_target_credentials "$index"
  else
    # The first target keeps environment-provided credentials. Later targets
    # must not inherit the previous target's answers.
    if ((index > 0)); then
      _reset_target_credentials
    fi
    var_reconfigure="$shared_reconfigure"
  fi
  VERIFIED_SITE=0
  VERIFIED_CLIENT=0
  VERIFIED_SLUGS=""
  VERIFIED_BACKEND="single"

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

  if [[ "$site" == 1 ]]; then
    _resolve_target_slug_plan "$target" || return 1
    st="$SLUG_TOTAL"
    multi="$SLUG_MULTI"
    if [[ "$multi" == 0 ]]; then
      # A converted or interrupted target must use the per-slug layout even
      # with a single default slug. The probe is read-only.
      if [[ "$(_target_site_layout "$target")" != single ]]; then
        multi=1
      fi
    fi
    TARGET_MULTI[index]="$multi"
    TARGET_SLUGS[index]="${SLUG_ARRAY[*]}"
    if [[ "$multi" == 1 ]]; then
      _prepare_multi_site_target "$target" "$reconfigure" || return 1
      site_answers=1
    else
      _warn_provisioning_risks "$reconfigure" "$site"
      site_answers="$(_resolve_site_answers "$target" "$reconfigure")" || return 1
      # The interactive legacy path types credentials per target with no
      # environment to scan, so dedupe the static site ID here, before any
      # change for this target. Unattended runs already validated the same
      # set in _validate_site_plan; recording again is consistent.
      if [[ "$site_answers" == 1 && -z "${var_site_provisioning_key:-}" ]] &&
        [[ -n "${var_site_id:-}" ]]; then
        _remember_site_id "$var_site_id" || return 1
      fi
      if ! _native_config_possible "$target" "$site_answers"; then
        msg_error "Native site interfaces are enabled but the existing site configuration does not match; set var_reconfigure=1 to apply them."
        return 1
      fi
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

  local flag_lines
  flag_lines="$(printf 'SITE=%s\nCLIENT=%s\nRECONFIGURE=%s\nTARGET=%s' \
    "$site" "$client" "$reconfigure" "$target")"
  if [[ "$site" == 1 ]]; then
    if [[ "$multi" == 1 ]]; then
      flag_lines+="$(printf '\nSITE_SLUGS=%s\nSSH_OWNER=%s\nMULTI_SITE=1' \
        "${SLUG_ARRAY[*]}" "$(_site_ssh_owner "$SLUG_LIST")")"
    else
      flag_lines+=$'\nMULTI_SITE=0'
    fi
  fi
  write_private_file "$answers/flags" "$flag_lines" || return 1

  if [[ "$site" == 1 && "$multi" == 1 ]]; then
    local slug
    for slug in "${SLUG_ARRAY[@]}"; do
      _activate_site_pair "$slug" "$target" "$st" "$tt"
      if [[ -z "${var_site_provisioning_key:-}" ]] &&
        { [[ -z "${var_site_id:-}" ]] || [[ -z "${var_site_secret:-}" ]]; }; then
        continue # the target already holds this slug's config
      fi
      ep="$(_site_pair_endpoint "$slug" "$target" "$st" "$tt")"
      if site_ssh_disabled "$(_site_ssh_owner "$SLUG_LIST")" "$slug"; then
        disable_ssh=1
      else
        disable_ssh=0
      fi
      local iface imain
      iface="$(_site_pair_interface "$slug" "$target" "$st" "$tt" client)"
      imain="$(_site_pair_interface "$slug" "$target" "$st" "$tt" main)"
      if [[ -n "${var_site_provisioning_key:-}" ]]; then
        if ((prov_warned == 0)); then
          _warn_provisioning_risks "$reconfigure" 1
          prov_warned=1
        fi
        name="${var_site_name:-}"
        if [[ -z "$name" ]]; then
          name="$(_default_provisioning_site_name "$target" "$slug")"
        fi
        if ! validate_site_name "$name"; then
          msg_error "Invalid site name; expected 1-63 characters with no control characters."
          return 1
        fi
        build_site_answers_to_path "$answers/sites/$slug.json" "$ep" \
          "${var_site_provisioning_key}" "$name" - - \
          "$var_site_native" "$var_site_native_main" "$iface" "$imain" \
          "$disable_ssh" || return 1
      else
        build_site_answers_to_path "$answers/sites/$slug.json" "$ep" - - \
          "${var_site_id}" "${var_site_secret}" \
          "$var_site_native" "$var_site_native_main" "$iface" "$imain" \
          "$disable_ssh" || return 1
      fi
    done
  elif [[ "$site" == 1 && "$site_answers" == 1 ]]; then
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
    if ! _remember_client_id "${var_client_id:-}"; then
      msg_error "The machine client ID is already used by another target in this run."
      return 1
    fi
    build_client_answers "$answers" "$var_pangolin_endpoint" \
      "$var_client_id" "$var_client_secret" || return 1
  fi

  payload_rc=0
  _run_target_payload "$target" "$answers" || payload_rc=$?

  # Read the markers even when the payload failed. A real multi-site partial
  # failure records a backend:<name> and site:<slug> marker for every
  # instance that verified before another slug failed, plus the legacy site
  # marker for a verified default. Those verified instances stay tagged and
  # summarized; an all-failed run records no markers and is not tagged. A
  # stale marker from an earlier run was already removed before the payload.
  _apply_verified_tags "$target" "$answers"
  if [[ "$multi" == 1 && "$site" == 1 ]]; then
    local vslug vstatus entries=""
    for vslug in "${SLUG_ARRAY[@]}"; do
      vstatus=failed
      if [[ " $VERIFIED_SLUGS " == *" $vslug "* ]]; then
        vstatus=verified
      fi
      entries+="  site $vslug: $vstatus"$'\n'
    done
    TARGET_SLUG_STATUS[index]="${entries%$'\n'}"
  fi
  # The remote copy is no longer needed once the marker is read.
  _remove_remote_answers "$target"

  # Tag and print next steps for the instances that actually verified, on a
  # full success and on a partial failure alike.
  local steps_printed=0
  if [[ "$VERIFIED_SITE" == 1 || "$VERIFIED_CLIENT" == 1 ]]; then
    steps_printed=1
    if [[ "$multi" == 1 && "$VERIFIED_SITE" == 1 && -n "$VERIFIED_SLUGS" ]]; then
      _print_next_steps "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT" \
        "$VERIFIED_SLUGS" "$VERIFIED_BACKEND"
    else
      _print_next_steps "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT"
    fi
  fi
  if ((payload_rc != 0)); then
    msg_error "The Pangolin install failed on $target. Components that were verified stay installed."
    return 1
  fi

  if ((steps_printed == 0)); then
    # A payload that succeeded without recording markers (an older payload
    # or a test stub): report the requested components.
    VERIFIED_SITE="$site"
    VERIFIED_CLIENT="$client"
    _print_next_steps "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT"
  fi
  return 0
}

# Full interactive or unattended flow. Secrets stay in the mode 0700 answers
# directories and never enter a pct argument value or a log line.
main() {
  # An inherited `bash -x` would print every credential assignment below.
  # Disable the trace before target resolution or credential loading.
  set +x
  local mode="" target="" site=0 client=0 reconfigure=0
  # Capture the raw operator interface overrides before _resolve_site_native
  # fills in the pangolin defaults, so _site_pair_interface can tell an unset
  # shared interface from an explicit one and fall back to the per-slug name.
  local SITE_INTERFACE_RAW="${var_site_interface:-}"
  local SITE_INTERFACE_MAIN_RAW="${var_site_interface_main:-}"
  SITE_INTERFACE_CAPTURED=1
  local var_site_native="${var_site_native-0}"
  local var_site_native_main="${var_site_native_main-0}"
  local var_site_interface="${var_site_interface-pangolin}"
  local var_site_interface_main="${var_site_interface_main-pangolin}"
  local -a missing=()
  local i total=0 target_out="" failed=0

  ANSWERS_DIR=""
  REMOTE_TARGET=""
  WORK_DIR=""
  NATIVE_PROMPTED=0
  SITE_OWNER_PROMPTED=0
  SITE_LABEL_PLAN=""
  SEEN_SITE_IDS=$'\n'
  SEEN_CLIENT_IDS=$'\n'
  SITE_PAIR_ID=()
  SITE_PAIR_SECRET=()
  SITE_PAIR_KEY=()
  SITE_PAIR_NAME=()
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
  TARGET_SLUGS=()
  TARGET_MULTI=()
  TARGET_SLUG_PLANS=()
  TARGET_SLUG_STATUS=()

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

  # Pre-change validation for the site plan. Slugs, SSH owner, interface
  # overrides, and static IDs are all provable from the environment before any
  # target is opened, so a duplicate or collision fails here with zero side
  # effects. The dry run additionally requires credentials for every slug
  # because it never probes a target.
  if [[ "$site" == 1 ]]; then
    _validate_site_plan "$PANGOLIN_DRY_RUN" || return 1
  fi
  if [[ "$client" == 1 ]]; then
    _validate_client_plan || return 1
  fi

  if [[ "$PANGOLIN_DRY_RUN" == 1 ]]; then
    printf 'Pangolin addon dry run\n'
    printf 'Selected targets: %s\n' "$total"
    for ((i = 0; i < total; i++)); do
      _activate_target_credentials "$i"
      _validate_plan "$site" "$client" "$reconfigure" || return 1
      _print_dry_run "$mode" "${TARGETS[i]}" "$site" "$client" "$reconfigure" \
        "${TARGET_SLUGS[i]:-default}" "${TARGET_MULTI[i]:-0}"
      printf '\n'
    done
    return 0
  fi

  if ! _ensure_curl; then
    echo "curl is required to fetch the Pangolin install payload" >&2
    return 1
  fi
  _load_core
  # Core helpers (load_functions/set_std_mode) can re-enable xtrace when
  # DEV_MODE_TRACE is set. Never trace credential activation.
  set +x
  # Pangolin art, not the generic community-scripts header.
  pangolin_header
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
