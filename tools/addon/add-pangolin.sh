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
#   var_target=host|<CTID>
#   Site/both: var_pangolin_endpoint=... var_site_id=... var_site_secret=...
#              or var_site_provisioning_key=... var_site_name=...
#   Client/both: var_client_id=... var_client_secret=...

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

# Load the payload at source time when a local checkout is supplied. Tests use
# this path so the entry helpers can be exercised without network access or a
# Proxmox host. Otherwise main() fetches the payload before it runs.
if [[ -n "${PANGOLIN_PAYLOAD:-}" && -r "$PANGOLIN_PAYLOAD" ]]; then
  # shellcheck disable=SC1090
  source "$PANGOLIN_PAYLOAD"
fi

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

# Write <dir>/site.json for a provisioning key or for static credentials.
# A dash means "not supplied"; the key wins when both forms are present.
build_site_answers() {
  local dir="$1" endpoint="$2" key="$3" name="$4" id="$5" secret="$6" config
  validate_endpoint "$endpoint" || {
    echo "Invalid Pangolin endpoint: $endpoint" >&2
    return 1
  }
  if [[ "$key" != "-" && -n "$key" ]]; then
    [[ "$name" == "-" ]] && name=""
    config="$(site_config_provisioning "$endpoint" "$key" "$name")"
  else
    if [[ "$id" == "-" || -z "$id" || "$secret" == "-" || -z "$secret" ]]; then
      echo "Site answers need a provisioning key or an id and secret" >&2
      return 1
    fi
    config="$(site_config_static "$endpoint" "$id" "$secret")"
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

# Print the target, prompting only in interactive mode. A target is `host` or a
# numeric CTID.
_resolve_target() {
  local target="${var_target:-}"
  if [[ -z "$target" ]]; then
    if _is_noninteractive; then
      echo "var_target is required (host or a CTID)" >&2
      return 1
    fi
    if ! command -v whiptail >/dev/null 2>&1; then
      echo "whiptail is required for interactive mode" >&2
      return 1
    fi
    target="$(whiptail --title "Pangolin Addon" \
      --inputbox "Target: host, or an LXC CTID" 10 60 "host" 3>&1 1>&2 2>&3)" || return 1
  fi
  if [[ "$target" == host ]]; then
    printf 'host\n'
    return 0
  fi
  if [[ "$target" =~ ^[0-9]+$ ]] && ((10#$target > 0)); then
    printf '%s\n' "$target"
    return 0
  fi
  echo "Invalid var_target: $target (expected host or a CTID)" >&2
  return 1
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
  local where="host" prefix=""
  if [[ "$target" != host ]]; then
    where="LXC CTID $target"
    prefix="pct exec $target -- "
  fi
  printf 'Pangolin addon dry run\n'
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
    printf '  - Install the pangolin-site service and verify provisioning\n'
    printf '  - Check status with: %spangolin service status site\n' "$prefix"
  fi
  if [[ "$client" == 1 ]]; then
    if [[ "$target" == host ]]; then
      printf '  - Ensure /dev/net/tun exists on the host; load the tun module when missing\n'
    else
      printf '  - Apply TUN passthrough and restart CTID %s gracefully when the config changes\n' \
        "$target"
    fi
    printf '  - Install the pangolin-client service with the provided credentials\n'
    printf '  - Check status with: %spangolin service status client\n' "$prefix"
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
# as reuse or replace; client credentials are always prompted when missing.
_prompt_inputs() {
  local target="$1" site="$2" client="$3" choice default_name
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

# Throw away the private answers directory on every exit path, including the
# copy pushed into an LXC container.
_cleanup_answers() {
  if [[ -n "${ANSWERS_DIR:-}" ]]; then
    rm -rf "$ANSWERS_DIR"
  fi
  if [[ -n "${REMOTE_TARGET:-}" ]]; then
    pct exec "$REMOTE_TARGET" -- rm -rf /root/.pangolin-addon >/dev/null 2>&1 || true
  fi
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

# Full interactive or unattended flow. Secrets stay in the mode 0700 answers
# directory and never enter a pct argument value or a log line.
main() {
  local mode="" target="" site=0 client=0 reconfigure=0 site_answers=0
  local payload_rc=0 name=""
  local -a runenv=() missing=()

  ANSWERS_DIR=""
  REMOTE_TARGET=""
  PANGOLIN_DRY_RUN="${PANGOLIN_DRY_RUN:-0}"

  reconfigure="${var_reconfigure:-0}"
  if [[ "$reconfigure" != 0 && "$reconfigure" != 1 ]]; then
    echo "Invalid var_reconfigure: $reconfigure (expected 0 or 1)" >&2
    return 1
  fi

  # Dry run must never open whiptail: require the unattended selectors first.
  if [[ "$PANGOLIN_DRY_RUN" == 1 ]]; then
    missing=()
    [[ -n "${var_mode:-}" ]] || missing+=("var_mode")
    [[ -n "${var_target:-}" ]] || missing+=("var_target")
    if ((${#missing[@]} > 0)); then
      echo "Missing required values: ${missing[*]}" >&2
      return 1
    fi
  fi

  mode="$(_resolve_mode)" || return 1
  target="$(_resolve_target)" || return 1
  read -r site client <<<"$(components_from_mode "$mode")" || return 1
  _apply_legacy_aliases

  if [[ "$PANGOLIN_DRY_RUN" == 1 ]]; then
    _validate_plan "$site" "$client" "$reconfigure" || return 1
    _print_dry_run "$mode" "$target" "$site" "$client" "$reconfigure"
    return 0
  fi

  if [[ "$target" != host ]]; then
    _ensure_lxc_running "$target" || return 1
  fi
  _validate_target_os "$target" || return 1
  if [[ "$target" == host && "$client" == 1 ]]; then
    _ensure_host_tun || return 1
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

  ANSWERS_DIR="$(mktemp -d)" || return 1
  chmod 0700 "$ANSWERS_DIR" || {
    rm -rf "$ANSWERS_DIR"
    ANSWERS_DIR=""
    return 1
  }
  trap _cleanup_answers EXIT

  if ! fetch_payload "$ANSWERS_DIR/payload.sh"; then
    msg_error "Failed to fetch the Pangolin install payload from $PANGOLIN_PAYLOAD_URL"
    return 1
  fi
  if ! bash -n "$ANSWERS_DIR/payload.sh"; then
    msg_error "The fetched Pangolin install payload failed bash -n"
    return 1
  fi
  # shellcheck disable=SC1090,SC1091
  source "$ANSWERS_DIR/payload.sh"

  if [[ "$target" != host ]]; then
    _apply_lxc_tun "$target" "$client" || return 1
    _ensure_lxc_runtime "$target" || {
      msg_error "CTID $target does not have a usable bash and curl runtime"
      return 1
    }
  fi
  if ! _is_noninteractive; then
    _prompt_inputs "$target" "$site" "$client" || return 1
    reconfigure="${var_reconfigure:-0}"
    [[ "$reconfigure" == 1 ]] || reconfigure=0
  fi
  _validate_plan "$site" "$client" "$reconfigure" || return 1
  _warn_provisioning_risks "$reconfigure" "$site"

  if [[ "$site" == 1 ]]; then
    site_answers="$(_resolve_site_answers "$target" "$reconfigure")" || return 1
  fi

  write_private_file "$ANSWERS_DIR/flags" \
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
      build_site_answers "$ANSWERS_DIR" "$var_pangolin_endpoint" \
        "$var_site_provisioning_key" "$name" - - || return 1
    else
      build_site_answers "$ANSWERS_DIR" "$var_pangolin_endpoint" - - \
        "$var_site_id" "$var_site_secret" || return 1
    fi
  fi
  if [[ "$client" == 1 ]]; then
    build_client_answers "$ANSWERS_DIR" "$var_pangolin_endpoint" \
      "$var_client_id" "$var_client_secret" || return 1
  fi

  if [[ -n "${var_pangolin_cli_version:-}" ]]; then
    export var_pangolin_cli_version
  fi
  if [[ -n "${var_pangolin_cli_sha256:-}" ]]; then
    export var_pangolin_cli_sha256
  fi

  if [[ "$target" == host ]]; then
    bash "$ANSWERS_DIR/payload.sh" "$ANSWERS_DIR" || payload_rc=$?
  else
    REMOTE_TARGET="$target"
    if ! push_payload "$target" "$ANSWERS_DIR/payload.sh" "$ANSWERS_DIR"; then
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
      bash /root/.pangolin-addon/payload.sh /root/.pangolin-addon || payload_rc=$?
  fi

  _apply_verified_tags "$target" "$ANSWERS_DIR"
  if ((payload_rc != 0)); then
    msg_error "The Pangolin install failed. Components that were verified stay installed."
    return "$payload_rc"
  fi
  if [[ "$VERIFIED_SITE" == 0 && "$VERIFIED_CLIENT" == 0 ]]; then
    VERIFIED_SITE="$site"
    VERIFIED_CLIENT="$client"
  fi
  _print_next_steps "$target" "$VERIFIED_SITE" "$VERIFIED_CLIENT"
  return 0
}

if [[ "${PANGOLIN_TEST}" != "1" ]] &&
  [[ "${BASH_SOURCE[0]}" == "$0" || "${BASH_SOURCE[0]}" == /dev/fd/* ]]; then
  main "$@"
fi
