#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Deprecated name. Thin wrapper so existing installs that fetch `ct/newt.sh`
# (e.g. an installed LXC's /usr/bin/update) keep working.
source <(curl -fsSL "${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}/ct/pangolin-site.sh")