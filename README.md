# Proxmox Custom Scripts

Community-scripts-compatible Proxmox VE helper scripts for applications **not** found in the [main community-scripts collection](https://github.com/community-scripts/ProxmoxVE).

**Website:** https://oraad.github.io/proxmox-scripts/

## Quick start

Run on your **Proxmox host** (not inside a VM or container):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/musicassistant.sh)"
```

### Alpine LXC

```bash
var_os=alpine var_version=3.24 bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/musicassistant.sh)"
```

Follow the community-scripts wizard (Default or Advanced install). After completion, open Music Assistant at:

```text
http://<container-ip>:8095
```

## Home Assistant MCP (ha-mcp)

Deploys the [Home Assistant MCP Server](https://github.com/homeassistant-ai/ha-mcp) via **uvx** in HTTP mode (`ha-mcp-web`) on port **8086**. Use this for Cursor, VS Code, and other HTTP-capable MCP clients on your LAN.

Run on your **Proxmox host**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/hamcp.sh)"
```

### Alpine LXC

```bash
var_os=alpine var_version=3.24 bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/hamcp.sh)"
```

During install you will be prompted for:

- **Home Assistant URL** (e.g. `http://192.168.1.10:8123`)
- **Long-lived access token** (HA Profile → Security → Create Token)

The script verifies HA connectivity before starting the service and prints the full MCP URL (includes a secret path).

Default resources: 1 CPU, 1024 MB RAM, 4 GB disk. No Docker nesting required.

### Cursor configuration

Add the URL printed at install completion to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "home-assistant": {
      "url": "http://<container-ip>:8086/mcp-<secret>/mcp"
    }
  }
}
```

Restart Cursor, then confirm the server connects in Settings → MCP.

### Update an existing ha-mcp container

From inside the LXC:

```bash
update
```

Or from the Proxmox host:

```bash
pct exec <CTID> -- update
```

Retrieve the MCP endpoint anytime:

```bash
pct exec <CTID> -- cat /opt/hamcp/mcp_endpoint.txt
```

**Note:** Home Assistant OS / Supervised users may prefer the official MCP Server add-on. This repo provides a standalone LXC path for Container/Core installs or shared LAN MCP access.

## Music Assistant

Deploys the [official Docker image](https://www.music-assistant.io/installation/) inside an LXC with:

- Docker + Docker Compose
- `network_mode: host` (required for player discovery)
- Default resources: 2 CPU, 2048 MB RAM, 8 GB disk
- LXC features: `nesting=1`, `keyctl=1`, unprivileged by default

**Note:** Music Assistant developers recommend the Home Assistant add-on. This repo provides an unofficial Docker-in-LXC path for homelab users who want a standalone MA server outside community-scripts.

### Update an existing container

From inside the LXC:

```bash
update
```

Or from the Proxmox host:

```bash
pct exec <CTID> -- update
```

## Repository layout

```text
ct/                 Host-side LXC creation scripts
install/            In-container install scripts
defaults/           App-specific wizard defaults
json/               Script metadata for the website
misc/build.func     Wrapper around upstream community-scripts build.func
frontend/           GitHub Pages catalog (Next.js static export)
```

## Adding a new script

1. Add `ct/<app>.sh` and `install/<app>-install.sh`
2. Add `json/<app>.json` metadata (see `json/musicassistant.json`)
3. Optionally add `defaults/<app>.vars` and `ct/headers/<app>`
4. Push to `main` — GitHub Actions rebuilds the site automatically

## Configuration

Repo URLs are set for `oraad/proxmox-scripts` in `misc/build.func`, `ct/*.sh`, `install/*-install.sh`, and `frontend/src/config/site-config.ts`.

## Troubleshooting

### ha-mcp cannot reach Home Assistant

Ensure the LXC and Home Assistant are on the same LAN/VLAN. Test from inside the container:

```bash
curl -sf -H "Authorization: Bearer YOUR_TOKEN" http://YOUR_HA_IP:8123/api/
```

Use `http://` unless you have configured HTTPS on HA. Regenerate the token in HA if it was revoked.

### ha-mcp service not running

Debian:

```bash
systemctl status ha-mcp
journalctl -u ha-mcp -n 50
```

Alpine:

```bash
rc-service ha-mcp status
tail -50 /var/log/ha-mcp.log
```

### Alpine template not found

Ensure the Proxmox template exists:

```bash
pveam update
pveam available --section system | grep alpine-3.24
```

If 3.24 is unavailable, use an older version: `var_version=3.23`.

### Docker fails inside LXC

Ensure the container has `nesting=1` and `keyctl=1` (defaults in this script). If host-network Docker still fails on unprivileged LXCs, try privileged mode:

```bash
var_unprivileged=0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/musicassistant.sh)"
```

### Players not discovered

Music Assistant requires layer-2 network access. MA, players, and Home Assistant should be on the same flat network or VLAN. Host networking is mandatory for the Docker container.

### GitHub Pages

Enable **Settings → Pages → Build and deployment → GitHub Actions** after pushing to GitHub.

## License

MIT — see [LICENSE](LICENSE).
