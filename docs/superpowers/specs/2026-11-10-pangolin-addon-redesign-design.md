# Pangolin CLI Addon Redesign — Design

- Date: 2026-11-10
- Status: proposed
- Scope: `tools/addon/add-pangolin.sh`, a new shared payload, addon metadata, tests
- Supersedes: the hand-rolled service and updater implementation in the current addon
- Deferred: converting `ct/pangolin-site.sh`, `install/pangolin-site-install.sh`, and `defaults/pangolin-site.vars` to the same payload

## Intent

Keep the addon's useful scope — install the official Pangolin CLI on the Proxmox host or an existing LXC, with Site mode and/or Machine Client mode — while fixing the defects found in review:

1. Secrets leak through `pct exec -- env` and through briefly world-readable env files.
2. The addon reinvents service management that the CLI now provides.
3. Binary downloads are unverified and depend on the rate-limited GitHub API.
4. Updates are unverified and stop the tunnel before a download succeeds.
5. Alpine services do not restart after a crash.
6. Host and LXC paths duplicate ~300 lines and have already drifted.
7. The addon prints success without checking that the service is running.
8. Interactive enrollment offers only site ID + secret, while Pangolin supports a provisioning key for sites.

The design also matches the community-scripts NetBird addon where that addon is stronger, and exceeds it where the Pangolin feature set allows.

## Prior art: NetBird addon

Reference: `community-scripts/ProxmoxVE/tools/addon/add-netbird-lxc.sh`.

| Dimension | NetBird addon | Pangolin addon today | This design |
|---|---|---|---|
| Scope | Existing LXC only, Debian/Ubuntu | Host or LXC, Debian/Ubuntu/Alpine | Same as today |
| Enrollment UX | No key prompt in the addon; LXC installer asks setup key/SSO/skip | Masked ID + secret only | Site provisioning key plus ID/secret fallback |
| Binary trust | apt repo, GPG-signed | Unsigned GitHub download | Official sha256, fail closed; optional pinned digest |
| Service manager | Vendor package + systemd | Hand-rolled, names diverge | Upstream `pangolin service`; OpenRC adapter on Alpine |
| TUN handling | Appends duplicate config every run | Idempotent grep guard | Keep idempotent guard, graceful restart |
| Post-install check | None; tells user to reboot | None; prints success | Verify unit active and provisioning exchange |
| Updates | apt upgrade via container update | Custom unverified updaters | CLI self-update / `pangolin update` |
| Core integration | `core.func`, `error_handler`, `require_pve_host` | Custom message functions, no trap | Adopt core functions in the entry point |

NetBird wins on binary provenance: a GPG-signed apt repository is stronger than a checksum fetched over TLS. Pangolin publishes no package or signature, so a verified checksum is the strongest available option. NetBird also wins on core-engine consistency; this design adopts that pattern.

Pangolin wins on scope, Alpine support, TUN idempotency, and (after this change) enrollment and post-install verification.

## Goals

- Verify the CLI binary against the official Fossorial release digest before installation.
- Support a site provisioning key (`spk-…`) as an interactive and unattended enrollment path.
- Keep site ID + secret as the universal fallback, because provisioning keys are gated to tier3/enterprise.
- Use `pangolin service install site|client` on systemd targets.
- Keep a small OpenRC backend on Alpine with restart supervision.
- Never place secrets in host process arguments or world-readable files.
- Verify the installed service and, for provisioning, verify that credentials were obtained.
- Share one install payload between host and LXC.
- Migrate existing standalone Newt installs and current Pangolin addon installs without losing credentials.
- Adopt community-scripts core helpers for the entry point.

## Non-goals

- No Pangolin server deployment. This addon only installs the client.
- No desktop app or GUI.
- No machine-client provisioning key. Pangolin exposes none.
- No unattended client service based on `pangolin login`. Upstream documents logged-in clients as interactive/manual.
- No Docker installation.
- No custom package repository.

## Deferred follow-up

`ct/pangolin-site.sh`, `install/pangolin-site-install.sh`, and `defaults/pangolin-site.vars` install the same stack with their own env file, wrapper, unit, and unverified `fetch_and_deploy_gh_release`. They are out of scope for this change, but the payload is designed to be reusable from that path. The follow-up will:

- replace the installer's hand-rolled unit/wrapper with the shared payload;
- make new LXC installs and addon-managed installs use the same config and service layout;
- migrate existing `pangolin-site` LXCs during their normal update.

Until then, the repo keeps that known duplication. This change does not claim to remove it outside the addon.

## Anti-goals

A change is a failure if it:

- prints or logs a secret;
- installs an unverified binary;
- overwrites a working service without a verified replacement and a restorable backup;
- leaves a service in a restart loop after invalid credentials;
- diverges from upstream service names or env paths;
- keeps the host/LXC payload duplicated.

## Verified CLI behavior (0.21.0)

Verified against the published Linux amd64 binary and its source:

- `pangolin up site --help` includes `-provisioning-key` (“One-time provisioning key used to obtain a newt ID and secret from the server”) and `-name`.
- Site config file keys: `endpoint`, `id`, `secret`, `provisioningKey`, `name`. `pangolin up site -config-file <path> -show-config` reads them.
- `pangolin service install site --config-file <path>` accepts a JSON config and passes it to the service through `CONFIG_FILE`; flags are optional when the file is set.
- `pangolin service install client` requires `--id`, `--secret`, and `--endpoint`; it has no config-file option.
- Service names are `pangolin-site` and `pangolin-client`; env files are `/etc/pangolin/pangolin-site.env` and `/etc/pangolin/pangolin-client.env`.
- The service manager is systemd-only (`CheckSupported` requires `systemctl`), so Alpine still needs OpenRC.
- Upstream provisioning writes the returned ID/secret into the config file, clears `provisioningKey`/`name`, and uses mode `0644` when it creates the file. Pre-create the file `0600`.
- Site self-update verifies the server-provided sha256 when present. `pangolin update` runs the official installer.
- The official installer gets `latestVersion` and per-asset sha256 from `https://api.fossorial.io/api/v1/versions/cli`, but falls back to an unverified download if that API is unavailable.
- Site provisioning keys are server-side and gated by the tier matrix to `tier3` and `enterprise`. Creation is not part of Community.
- Provisioning keys support max uses, expiry, and an “approve new sites” flag. With approval off, the site is created `pending`.
- Minimum supported CLI version: `0.21.0`. Pinned versions below it are refused, because `--config-file`, provisioning keys, and service behavior are verified against 0.21.0 only.

The 0.21.0 Linux amd64 binary's sha256 matched the Fossorial API digest (`c34937dc…3736c6`).

## Settled decisions

These were open during the builder check and are settled here as the author's calls:

- Components install independently. If site succeeds and client fails, site stays installed and verified; the run exits nonzero and reports the partial result. No cross-component rollback. Legacy Newt is removed only after the site service is verified.
- Any `var_mode` value selects non-interactive mode. Missing required values fail with a list instead of prompting. Interactive mode runs only when `var_mode` is unset. `var_unattended=1` is accepted as an explicit alias.
- An existing verified site config is reused by default. New site credentials replace it only with `var_reconfigure=1`; without it they are ignored with a notice. New client credentials always replace the existing client service.
- `var_reconfigure=1` with a provisioning key creates a second server-side site. The addon warns that the old site must be deleted in the dashboard; it does not attempt server-side deletion.
- “No secret in `ps`” is an acceptance criterion for site mode. Client install-time argv exposure is the documented upstream limitation.
- A same-named upstream unit is backed up before overwrite and restored on failure. The anti-goal is no *unrecoverable* overwrite, not no overwrite.
- Supported OS floors: Debian 12+, Ubuntu 22.04+, Alpine 3.20+.

## Approaches considered

### A. Patch in place

Add a provisioning-key prompt and a checksum check to the current script. Keep the existing units, updaters, and duplicated payload.

- Pros: smallest diff, no migration.
- Cons: keeps all architectural defects, divergent service names, unverified update path, and the 300-line duplication. Rejected.

### B. Upstream-first (chosen)

Use a JSON config and `pangolin service install site` on systemd; use `pangolin service install client`; keep a small OpenRC backend for Alpine; share one payload; verify the binary; remove custom updaters.

- Pros: uses the CLI's supported service lifecycle, keeps site secrets out of argv, removes most parallel implementation, fixes trust and verification.
- Cons: medium rewrite; client service install still takes credentials as flags at install time (upstream limitation); systemd and OpenRC need separate backend code.

### C. Thin bootstrap

Call `get-cli.sh` and `pangolin service install` directly, with no shared payload or OpenRC support.

- Pros: least code.
- Cons: loses Alpine, accepts the installer's unverified fallback, loses migration and verification control. Rejected.

## Design

### File layout

- `tools/addon/add-pangolin.sh` — entry point: UI, target selection, preflight, TUN, payload transport, summary.
- `tools/addon/lib/pangolin-payload.sh` — shared install payload: binary verification, config generation, service backends, verification, migration.
- `tools/addon/tests/pangolin-addon-test.sh` — pure-function tests for arch mapping, digest parsing, JSON generation, tag handling, TUN detection, backend selection.
- `tools/addon/add-pangolin-site.sh`, `add-pangolin-cli.sh`, `add-newt.sh` — unchanged wrappers that set `var_mode` and source the entry point.
- `json/add-pangolin.json` — updated notes and config paths.
- `README.md` — only if its addon description needs correction.

The entry point fetches the payload from `REPO_RAW`, checks it with `bash -n`, and transfers it to the target. A local override `PANGOLIN_PAYLOAD` may point at a checkout for development.

### Entry flow

1. Bootstrap `curl` if missing. Source community-scripts core files and call `load_functions`, `header_info`, `require_pve_host`; install an `ERR` trap with `error_handler`. Initialize tool telemetry when available.
2. Parse `var_*` values. Interactive mode uses whiptail; unattended mode never prompts.
3. Select components (`site`, `client`, `both`) and target (`host` or an LXC CTID). Validate the CTID and start the container if stopped.
4. Validate the target OS: Debian 12+, Ubuntu 22.04+, or Alpine 3.20+. Install `bash` in Alpine before running the payload.
5. For client mode in an LXC, ensure TUN passthrough before installing; restart gracefully only when the container config changed.
6. Build a private answers directory (`0700`):
   - `answers/site.json` — site config for provisioning or static credentials
   - `answers/client.env` — client credentials
   - `answers/flags` — non-secret flags: `SITE`, `CLIENT`, `RECONFIGURE`, `TARGET`
7. Transfer the answers directory and payload:
   - Host: run the payload against the directory under `/run/…`.
   - LXC: `pct push` the payload and answers into `/root/.pangolin-addon` with modes `700`/`600`, then `pct exec … bash /root/.pangolin-addon/payload.sh`.
8. Remove the answers directory on exit, success or failure.
9. Add or replace LXC tags: `pangolin-site`, `pangolin-client`; replace the old `pangolin-cli` tag if present.
10. Print component-specific status commands and next steps.

No secret is passed through `pct exec -- env`, shell history, or process arguments on the host.

### Credential modes

#### Site provisioning key (net-new)

- Prompt: “Site provisioning key (spk-…)” with masked input.
- Prompt for endpoint (default `https://app.pangolin.net`) and site name (default target hostname).
- Write `/etc/pangolin/site.json` mode `0600`:

```json
{
  "endpoint": "https://pangolin.example.com",
  "provisioningKey": "spk-...",
  "name": "pve-node-1"
}
```

- Install the service with `pangolin service install site --config-file /etc/pangolin/site.json`.
- The CLI exchanges the key on first start and rewrites the same file with `id` and `secret`, clearing the key.
- After install, poll for `"id"` and `"secret"` in the file for up to 30 seconds. If they do not appear, stop the service, print the last log lines, and fail. This prevents a restart loop with a used or invalid key.
- Warn that provisioning keys require tier3/enterprise and that “approve new sites” must be enabled for unattended use.

#### Site ID + secret (universal fallback)

- Masked prompts, or `var_site_id`/`var_site_secret` (legacy `var_newt_id`/`var_newt_secret`).
- Write `/etc/pangolin/site.json` mode `0600` with `endpoint`, `id`, `secret`.
- Use the same `--config-file` service install. No secret reaches the service unit or `pct exec` environment.

#### Machine client

- Masked prompts, or `var_client_id`/`var_client_secret`.
- On systemd: `pangolin service install client --id … --secret … --endpoint …`. Credentials appear briefly in the installer process arguments; upstream offers no config-file alternative. The answers directory keeps them out of the host entry process and shell history.
- On Alpine: write `/etc/pangolin/pangolin-client.env` mode `0600` with `PANGOLIN_CLIENT_ID`, `PANGOLIN_CLIENT_SECRET`, `PANGOLIN_ENDPOINT`; the OpenRC wrapper sources it.

#### Existing configuration and rotation

- If `/etc/pangolin/site.json` already contains `id` and `secret`, reuse it by default. New site credentials are ignored with a notice unless `var_reconfigure=1`.
- In interactive mode with an existing verified site config, ask “reuse / replace” instead of silently ignoring new input.
- `var_reconfigure=1` replaces the site config and service. With a provisioning key it creates a new server-side site; warn that the old site must be deleted in the dashboard.
- Client credentials always replace the existing client service; no separate reconfigure flag.
- If a legacy `/etc/pangolin/pangolin-site.env` exists, convert `SITE_ID`/`SITE_SECRET`/`PANGOLIN_ENDPOINT` into the JSON file before installing.
- Never print the secret back in the summary.

### Binary installation and trust

- Metadata URL: `https://api.fossorial.io/api/v1/versions/cli`.
- Default target: `latestVersion`; optional `var_pangolin_cli_version` pins a version.
- Asset: `pangolin-cli_linux_${arch}` where arch is `amd64`, `arm64`, `arm32`, `arm32v6`, or `riscv64`.
- Digest: from `assetDigests` in the metadata response. For pinned versions, require `var_pangolin_cli_sha256` because the metadata endpoint describes the latest release.
- Refuse pinned versions below `0.21.0`.
- Fail closed: missing digest, missing sha256 tool, download error, or mismatch aborts before replacing the live binary.
- Download to a temporary file in `/usr/local/bin`, verify, `chmod 755`, smoke-test `pangolin version`, then atomic `mv`.
- Record the accepted artifact in `/var/lib/pangolin/cli.json` as `{version, asset, sha256}` mode `0644`.
- On rerun, if the record exists, the installed binary's sha256 matches the record, and the target version matches, skip the metadata request and download. This keeps offline/idempotent reruns working and preserves local verification.
- If the metadata endpoint is unreachable and no valid local record exists, fail closed.
- Do not use the GitHub API; this avoids the unauthenticated 60-request hourly limit.
- Do not use `get-cli.sh`; its unverified fallback conflicts with fail-closed trust.
- Restore the SELinux context with `restorecon` when SELinux is enforcing.
- Document the trust anchor and the optional pinned digest. Propose upstream cosign/GitHub attestations separately; do not block this change on them.

### Service backends

#### systemd

- Detect `[[ -d /run/systemd/system ]]`.
- Site: `pangolin service install site --config-file /etc/pangolin/site.json`.
- Client: `pangolin service install client --id … --secret … --endpoint …`.
- The CLI writes `/etc/systemd/system/pangolin-site.service` or `pangolin-client.service`, env files under `/etc/pangolin`, and enables/starts the unit.
- The unit uses the absolute path of the running `pangolin` binary. Install to `/usr/local/bin/pangolin` first.

#### OpenRC (Alpine)

- Unit names remain `pangolin-site` and `pangolin-client`.
- Use `supervisor=supervise-daemon`, `respawn_delay=2`, `respawn_max=0`, `command_user=root`, and `depend() { need net; after firewall; }`.
- Site wrapper:

```sh
#!/bin/sh
CONFIG_FILE=/etc/pangolin/site.json
export CONFIG_FILE
exec /usr/local/bin/pangolin up site
```

- Client wrapper sources `/etc/pangolin/pangolin-client.env` and execs `pangolin up client --attach`.
- Logs: `/var/log/pangolin-site.log` and `/var/log/pangolin-client.log`. Install `/etc/logrotate.d/pangolin` when `logrotate` exists.
- Require `supervise-daemon`; fail with an actionable message if missing. Do not silently fall back to a non-restarting unit.

### TUN handling

- Keep the idempotent config guard for `lxc.cgroup2.devices.allow` and `lxc.mount.entry`.
- The helper reports “changed” through an out variable, not an inverted exit code.
- When changed, use `pct shutdown --timeout 60` followed by `pct start`; do not hard-stop a running container.
- On the host, for client mode, ensure `/dev/net/tun` exists or `modprobe tun` succeeds before installing.
- Do not add TUN for site-only mode.

### Verification and failure handling

- After service install, poll `systemctl is-active` or `rc-service … status` for up to 30 seconds.
- For provisioning, additionally poll the site JSON for `id` and `secret`.
- On failure: stop the unit to stop the restart loop, print the last 20 log lines, leave the config for debugging, and exit nonzero.
- Never print success before verification.
- Do not remove legacy units or credentials until the replacement is verified.
- Components are installed and verified independently. If site succeeds and client fails, leave site running, exit nonzero, and report the partial result. Do not roll site back.
- Back up same-named units and env files before overwrite. Restore the backup if the replacement fails verification.

### Migration

#### Standalone Newt

- Detect `/etc/newt/newt.env` on the target and read `NEWT_ID`, `NEWT_SECRET`, `PANGOLIN_ENDPOINT`.
- Prefer those credentials for site install unless the operator supplied new ones.
- After the new site service is verified: stop/disable `newt`, remove its unit/init script, binary, env, updater, and `/root/.newt`.
- Keep the `newt` dialog package on Alpine; remove only `/usr/local/bin/newt`.

#### Current Pangolin addon

- Site: convert `/etc/pangolin/pangolin-site.env` (`SITE_ID`, `SITE_SECRET`, `PANGOLIN_ENDPOINT`) into `/etc/pangolin/site.json`, then install the upstream unit over the old one.
- Client: read `/etc/pangolin-cli/client.env`, install upstream `pangolin-client`, then stop/disable/remove `pangolin-cli.service` or `/etc/init.d/pangolin-cli`, its wrapper, and `/etc/pangolin-cli`.
- Binary: install `/usr/local/bin/pangolin`; remove the old `/root/.pangolin-cli` marker. Remove `/usr/local/bin/pangolin-cli` only after no service references it.
- Back up units and env files to `/var/lib/pangolin/backup/` before overwriting. On failure, restore the backup and report the path.

### Updates

- Remove generated `update-pangolin-site` and `update-pangolin-cli` scripts.
- Keep them for one release as compatibility wrappers:

```sh
#!/usr/bin/env bash
exec /usr/local/bin/pangolin update
```

- Do not write `/usr/bin/update`.
- Document that site mode self-updates with a server-provided sha256, and client mode can use `pangolin update`.
- `pangolin update` uses the official installer, which is best-effort when the digest API is unreachable; the addon install path remains fail-closed.

### Configuration and unattended interface

Any `var_mode` selects non-interactive mode. Missing required values fail with a list instead of prompting. `var_unattended=1` is an explicit alias. Interactive mode runs only when `var_mode` is unset.

- `var_mode=site|client|both`
- `var_target=host|<CTID>`
- `var_pangolin_endpoint`
- Site: `var_site_id` + `var_site_secret`, or `var_site_provisioning_key` + `var_site_name`
- Client: `var_client_id` + `var_client_secret`
- `var_reconfigure=1` to replace an existing site config
- `var_pangolin_cli_version`, `var_pangolin_cli_sha256`
- Legacy aliases: `var_newt_id`, `var_newt_secret`

Interactive site enrollment menu:

```text
Site credentials:
  1) Site ID + secret (works on every Pangolin edition)
  2) Site provisioning key (tier3/enterprise; dashboard > Settings > Provisioning > Keys)
```

Default is 1 so the common path does not fail on Community. Choosing 2 asks for the key, endpoint, and site name.

### Core integration and messages

- Entry point sources `core.func`, `tools.func`, and `error_handler.func` like the NetBird addon.
- Use core `msg_info`, `msg_ok`, `msg_warn`, `msg_error`, `header_info`, `require_pve_host`, and telemetry when available.
- Payload keeps a four-line local message fallback so it remains runnable inside minimal containers without a second network fetch.
- Replace the leftover Newt ASCII banner with the core header.

### Metadata

Update `json/add-pangolin.json`:

- `config_path`: `/etc/pangolin` for both components.
- Notes: provisioning key, paid-tier caveat, upstream service commands (`pangolin service status|logs|uninstall`), Alpine support, binary verification, new unattended variables.
- Remove the custom updater note or mark the wrappers deprecated.
- Keep host/LXC and TUN notes.

## Security considerations

- Secrets live only in `0600` files inside a `0700` answers directory and in the final service config/env file.
- Pre-create the site JSON `0600` before the CLI writes credentials; upstream uses `0644` on create.
- Do not run `pangolin up site --show-config` in the addon; it prints the provisioning key unmasked.
- Do not log secrets or include them in status output.
- No secret in `pct exec -- env`, host argv, shell history, or unit files.
- Fail closed on missing or mismatched digests.
- Client install-time argv exposure is accepted as an upstream limitation and documented.

## Testing and proof

### Automated

- `bash -n` on the entry point and payload.
- ShellCheck severity error, matching CI.
- New pure-function test script run in CI:
  - arch mapping for amd64, arm64, armhf, armv6l, riscv64, unknown;
  - digest parsing from a compact API fixture and a missing-digest case;
  - JSON escaping and site config generation;
  - exact tag add/replace;
  - TUN change detection on a temp container config;
  - backend selection for systemd, OpenRC, and neither.
- Negative checksum test: a fake digest must abort before `mv`.

### Manual matrix

- Host Debian PVE: site static, site provisioning (paid account), client, both.
- Debian 13 LXC: site static, site provisioning, client with TUN restart.
- Alpine 3.24 LXC: site, client, OpenRC crash/restart.
- Failure cases: invalid provisioning key, used key, checksum mismatch, no digest, service fails to start.
- Migration: existing Newt LXC, existing Pangolin addon site, existing `pangolin-cli` client.

### Acceptance evidence

- `pangolin version` matches the target version.
- `sha256sum /usr/local/bin/pangolin` matches the published digest.
- `systemctl status pangolin-site` or `rc-service pangolin-site status` shows active.
- Provisioned `site.json` contains `id` and `secret` and no `provisioningKey`.
- No secret appears in host `ps` during site install. Client install-time argv exposure is accepted and documented.
- `pangolin service status site` and `pangolin service status client` work.

## Rollback

- Backups live in `/var/lib/pangolin/backup/`.
- On failed install, restore the previous unit and env file and restart the previous service.
- Manual rollback: `pangolin service uninstall site|client`, then restore the backup and `systemctl daemon-reload` or `rc-update add`.
- Removing the addon does not remove credentials or the binary by default.

## Open items for the builder

- Exact OpenRC `supervise-daemon` syntax supported by Alpine 3.20+; verify `respawn_max=0` behavior.
- Whether LXC `pct push --perms` is available on the minimum supported Proxmox version; otherwise `pct exec chmod`.
- Add the new test script to `.github/workflows/ci.yml`; if the repo prefers no new CI job, keep it as a documented local test target.
- Follow-up: convert `ct/pangolin-site.sh`, `install/pangolin-site-install.sh`, and `defaults/pangolin-site.vars` to the shared payload, and migrate existing Pangolin LXCs during their normal update.
