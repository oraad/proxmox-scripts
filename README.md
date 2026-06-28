# Proxmox Custom Scripts

Community-scripts-compatible Proxmox VE helper scripts for applications **not** found in the [main community-scripts collection](https://github.com/community-scripts/ProxmoxVE).

**Website:** https://oraad.github.io/proxmox-scripts/

Browse the catalog for install commands, resource defaults, and per-script notes.

## What is this?

One-command LXC installations for self-hosted applications missing from community-scripts. Paste a command into your Proxmox shell, answer a few prompts, and the container is ready.

Current scripts:

- [Music Assistant](https://oraad.github.io/proxmox-scripts/scripts) — Docker server with host networking
- [HA MCP](https://oraad.github.io/proxmox-scripts/scripts) — ha-mcp HTTP endpoint for Cursor and other MCP clients

## Getting started

1. Go to **[oraad.github.io/proxmox-scripts](https://oraad.github.io/proxmox-scripts/)**
2. Open the script you want and copy the one-line install command
3. Run it on your **Proxmox host** (not inside a VM or container)
4. Choose **Default** or **Advanced** in the wizard and follow the prompts

### Quick example (Music Assistant)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/musicassistant.sh)"
```

Alpine LXC:

```bash
var_os=alpine var_version=3.24 bash -c "$(curl -fsSL https://raw.githubusercontent.com/oraad/proxmox-scripts/main/ct/musicassistant.sh)"
```

Per-script install details, ports, warnings, and troubleshooting live on each script page in the catalog (`json/<slug>.json` powers the site).

## How scripts work

**Default mode** — Sensible resource defaults with minimal prompts.

**Advanced mode** — Full control over container settings before install.

After installation, each container includes an **`update`** command (also via `pct exec <CTID> -- update` from the host) to pull the latest application version.

## Repository layout

```text
ct/                 Host-side LXC creation scripts
install/            In-container install scripts
defaults/           App-specific wizard defaults
json/               Script metadata for the website (per-script docs)
misc/build.func     Wrapper around upstream community-scripts build.func
frontend/           GitHub Pages catalog (Next.js static export)
```

## Adding a new script

1. Add `ct/<app>.sh` and `install/<app>-install.sh`
2. Add `json/<app>.json` metadata — description, notes, links (see `json/musicassistant.json`)
3. Optionally add `defaults/<app>.vars` and `ct/headers/<app>`
4. Push to `main` — GitHub Actions rebuilds the site automatically

## Configuration

Repo URLs are set for `oraad/proxmox-scripts` in `misc/build.func`, `ct/*.sh`, `install/*-install.sh`, and `frontend/src/config/site-config.ts`.

## GitHub Pages

Enable **Settings → Pages → Build and deployment → GitHub Actions** after pushing to GitHub.

## License

MIT — see [LICENSE](LICENSE).
