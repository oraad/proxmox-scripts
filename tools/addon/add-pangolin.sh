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
#              or var_pangolin_provisioning_key=... var_site_name=...
#   Client/both: var_client_id=... var_client_secret=...

set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}"
PANGOLIN_PAYLOAD_URL="${PANGOLIN_PAYLOAD_URL:-$REPO_RAW/tools/addon/lib/pangolin-payload.sh}"
PANGOLIN_TEST="${PANGOLIN_TEST:-0}"

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
    "$id" "$secret" "$endpoint")"
  install -d -m 0700 "$dir" || return 1
  write_private_file "$dir/client.env" "$content"
}

# Task 10 replaces this with the interactive/unattended orchestration. Until
# then, make the payload load path reachable and fail with a clear message.
main() {
  if [[ -z "${PANGOLIN_PAYLOAD:-}" || ! -r "$PANGOLIN_PAYLOAD" ]]; then
    local payload
    payload="$(mktemp)" || return 1
    if ! fetch_payload "$payload"; then
      rm -f "$payload"
      echo "Failed to fetch the Pangolin install payload from $PANGOLIN_PAYLOAD_URL" >&2
      return 1
    fi
    if ! bash -n "$payload"; then
      rm -f "$payload"
      echo "The fetched Pangolin install payload failed bash -n" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    source "$payload"
    rm -f "$payload"
  fi
  echo "Pangolin addon orchestration is not implemented yet." >&2
  return 1
}

if [[ "${PANGOLIN_TEST}" != "1" ]] &&
  [[ "${BASH_SOURCE[0]}" == "$0" || "${BASH_SOURCE[0]}" == /dev/fd/* ]]; then
  main "$@"
fi
