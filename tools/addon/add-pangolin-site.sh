#!/usr/bin/env bash
# Copyright (c) 2026 Proxmox Custom Scripts contributors
# License: MIT
# Deprecated name. Superseded by the unified Pangolin Addon
# (tools/addon/add-pangolin.sh). Thin wrapper that enables Site mode only.
export var_mode=site
source <(curl -fsSL "${REPO_RAW:-https://raw.githubusercontent.com/oraad/proxmox-scripts/main}/tools/addon/add-pangolin.sh")