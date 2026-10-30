#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Deprecated name. Thin wrapper so existing installs that fetch
# `install/newt-install.sh` keep working.
src="$(curl -fsSL "${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}/install/pangolin-site-install.sh")" || {
  echo "ERROR: failed to fetch install/pangolin-site-install.sh" >&2
  exit 1
}
# <(printf ...) not /dev/stdin <<< — the sourced installer needs the terminal on fd0
source <(printf '%s\n' "$src")
