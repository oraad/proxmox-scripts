#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Deprecated name. Thin wrapper so existing installs that fetch `ct/newt.sh`
# (e.g. an installed LXC's /usr/bin/update) keep working.
echo "ℹ️  ct/newt.sh is deprecated — it now installs the Pangolin CLI site client (ct/pangolin-site.sh)" >&2
src="$(curl -fsSL "${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}/ct/pangolin-site.sh")" || {
  echo "ERROR: failed to fetch ct/pangolin-site.sh" >&2
  exit 1
}
# <(printf ...) not /dev/stdin <<< — the sourced wizard needs the terminal on fd0
source <(printf '%s\n' "$src")
