#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Deprecated name. Thin wrapper so existing installs that fetch
# `install/newt-install.sh` keep working.
source <(curl -fsSL "${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}/install/pangolin-site-install.sh")