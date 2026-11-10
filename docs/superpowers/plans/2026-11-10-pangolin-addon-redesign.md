# Pangolin CLI Addon Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the addon's hand-rolled service, update, and download code with the upstream Pangolin service manager, verified binary downloads, provisioning-key enrollment, and one shared payload for host and LXC installs.

**Architecture:** `tools/addon/add-pangolin.sh` remains the interactive entry point. It fetches and sources `tools/addon/lib/pangolin-payload.sh`, builds a private answers directory, and runs the payload on the host or inside the target LXC. The payload owns binary verification, credential files, systemd/OpenRC service backends, verification, and migration. Systemd uses `pangolin service install site|client`; Alpine uses OpenRC units named the same as upstream.

**Tech Stack:** Bash, Proxmox `pct`, systemd, OpenRC `supervise-daemon`, whiptail, community-scripts core, Fossorial release metadata API, sha256.

**Spec:** `docs/superpowers/specs/2026-11-10-pangolin-addon-redesign-design.md`

## Global Constraints

- Minimum Pangolin CLI version: `0.21.0`. Refuse pinned versions below it.
- Supported OS floors: Debian 12+, Ubuntu 22.04+, Alpine 3.20+.
- Service names: `pangolin-site` and `pangolin-client`. Site env path `/etc/pangolin/pangolin-site.env`; client env `/etc/pangolin/pangolin-client.env`.
- Site config file: `/etc/pangolin/site.json`, pre-created mode `0600`.
- Binary: `/usr/local/bin/pangolin`, state `/var/lib/pangolin/cli.json`, backups `/var/lib/pangolin/backup/`.
- No secret in host argv, `pct exec -- env`, shell history, unit files, or logs. Client install-time argv exposure is the documented upstream limitation.
- Fail closed on missing or mismatched sha256.
- Any `var_mode` means non-interactive; missing required values fail, never prompt.
- Existing verified site config is reused unless `var_reconfigure=1`. New client credentials always replace.
- Addon-only scope. Do not modify `ct/pangolin-site.sh`, `install/pangolin-site-install.sh`, or `defaults/pangolin-site.vars` in this plan.
- All shell files pass `bash -n` and ShellCheck severity error.

## Review Focus

- A valid provisioning key with “approve new sites” disabled creates a `pending` site; the service is active but carries no traffic. Manual test in Task 10; operator warning in Task 9.
- Values containing quotes, backslashes, or newlines must not corrupt `site.json`. Tested in Task 2.
- A same-named working unit is overwritten before the new one is verified. Backup/restore is tested in Task 8.
- Site succeeds and client fails in `both` mode. Partial-result behavior is tested in Task 10.
- Alpine `supervise-daemon` is missing or does not respawn. Backend detection is tested in Task 3; restart behavior is manual in Task 7.

---

### Task 1: Payload skeleton, architecture, release metadata, digest verification

**Files:**
- Create: `tools/addon/lib/pangolin-payload.sh`
- Create: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `arch_from_uname <machine>` → stdout `amd64|arm64|arm32|arm32v6|riscv64`; return 1 unknown.
  - `arch_from_dpkg <arch>` → stdout same mapping.
  - `detect_arch` → stdout arch; uses dpkg when present, otherwise `uname -m`.
  - `release_version <json>` → stdout version.
  - `release_digest <json> <asset>` → stdout 64-hex sha256; return 1 missing.
  - `verify_sha256 <path> <expected>` → 0 match, 1 mismatch or missing tool.

- [ ] **Step 1: Write the failing tests**

Create `tools/addon/tests/pangolin-addon-test.sh` with this harness and cases:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$ROOT/lib/pangolin-payload.sh"

# shellcheck source=../lib/pangolin-payload.sh
source "$PAYLOAD"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }

assert_eq amd64 "$(arch_from_uname x86_64)"
assert_eq arm64 "$(arch_from_uname aarch64)"
assert_eq arm32 "$(arch_from_uname armv7l)"
assert_eq arm32v6 "$(arch_from_uname armv6l)"
assert_eq riscv64 "$(arch_from_uname riscv64)"
if arch_from_uname mips >/dev/null 2>&1; then fail "mips should be unsupported"; fi
assert_eq arm32 "$(arch_from_dpkg armhf)"
assert_eq amd64 "$(arch_from_dpkg amd64)"

API_JSON='{"data":{"latestVersion":"0.21.0","assetDigests":{"pangolin-cli_linux_amd64":"c34937dc21f6e447e1023b5e5f36fb2266c997c3866e979a7cead23b4a3736c6"}}}'
assert_eq "0.21.0" "$(release_version "$API_JSON")"
assert_eq "c34937dc21f6e447e1023b5e5f36fb2266c997c3866e979a7cead23b4a3736c6" \
  "$(release_digest "$API_JSON" pangolin-cli_linux_amd64)"
if release_digest "$API_JSON" pangolin-cli_linux_arm64 >/dev/null 2>&1; then
  fail "missing digest should fail"
fi

tmp="$(mktemp)"
printf abc >"$tmp"
verify_sha256 "$tmp" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ||
  fail "known digest should verify"
if verify_sha256 "$tmp" deadbeef >/dev/null 2>&1; then fail "bad digest should fail"; fi
rm -f "$tmp"

echo "Task 1 tests passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL because `tools/addon/lib/pangolin-payload.sh` does not exist.

- [ ] **Step 3: Implement the payload helpers**

Create `tools/addon/lib/pangolin-payload.sh`. Set path variables with `PANGOLIN_ROOT` support:

```bash
PANGOLIN_ROOT="${PANGOLIN_ROOT:-}"
p() { printf '%s%s' "$PANGOLIN_ROOT" "$1"; }

PANGOLIN_BIN="${PANGOLIN_BIN:-$(p /usr/local/bin/pangolin)}"
PANGOLIN_STATE_FILE="${PANGOLIN_STATE_FILE:-$(p /var/lib/pangolin/cli.json)}"
PANGOLIN_RELEASE_API="${PANGOLIN_RELEASE_API:-https://api.fossorial.io/api/v1/versions/cli}"
PANGOLIN_RELEASE_BASE="${PANGOLIN_RELEASE_BASE:-https://github.com/fosrl/cli/releases/download}"
```

Implement `arch_from_uname`, `arch_from_dpkg`, `detect_arch`, `release_version`, `release_digest`, `verify_sha256`. Use `sed -n` for JSON extraction. `verify_sha256` tries `sha256sum`, then `shasum -a 256`; returns 1 when neither exists.

End the file with a source guard:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  payload_main "$@"
fi
```

`payload_main` is added in Task 10; for now define a stub that prints an error and returns 1.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 1 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`
Expected: no output.

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): add verified Pangolin download helpers"
```

---

### Task 2: Site JSON, private files, and tag helpers

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `json_escape <value>` → stdout escaped for a JSON string.
  - `site_config_static <endpoint> <id> <secret>` → stdout JSON.
  - `site_config_provisioning <endpoint> <key> <name>` → stdout JSON.
  - `site_config_has_credentials <path>` → 0 when `id` and `secret` exist and `provisioningKey` is absent.
  - `write_private_file <path> <content>` → creates parent dir `0755`, file `0600`.
  - `add_tag <current> <tag>` → stdout semicolon list without duplicates.
  - `remove_tag <current> <tag>` → stdout semicolon list with exact tag removed.

- [ ] **Step 1: Write the failing tests**

Append to the test script:

```bash
assert_eq 'a\"b\\c' "$(json_escape 'a"b\c')"
assert_eq 'a\nb' "$(json_escape "$(printf 'a\nb')")"

static="$(site_config_static "https://p.example" "id1" "sec1")"
python3 - "$static" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {"endpoint": "https://p.example", "id": "id1", "secret": "sec1"}, d
PY

prov="$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
python3 - "$prov" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {"endpoint": "https://p.example", "provisioningKey": "spk-1.secret", "name": "pve-1"}, d
PY

tmpd="$(mktemp -d)"
write_private_file "$tmpd/site.json" "$static"
[[ "$(stat -c '%a' "$tmpd/site.json")" == "600" ]] || fail "site config mode"
site_config_has_credentials "$tmpd/site.json" || fail "static config should have credentials"
write_private_file "$tmpd/prov.json" "$prov"
if site_config_has_credentials "$tmpd/prov.json"; then fail "provisioning config lacks credentials"; fi

assert_eq "a;b" "$(add_tag "a;b" "b")"
assert_eq "x" "$(add_tag "" "x")"
assert_eq "a;b" "$(remove_tag "a;pangolin-cli;b" "pangolin-cli")"
rm -rf "$tmpd"

echo "Task 2 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `json_escape: command not found` (or equivalent).

- [ ] **Step 3: Implement the helpers**

Escape backslash, double quote, newline, carriage return, and tab in `json_escape`. Build the JSON with `printf` and escaped values. `write_private_file` uses `install -d -m 0755 "$(dirname "$path")"`, `install -m 0600 /dev/null "$path"`, then `printf '%s\n' "$content" >"$path"`.

`site_config_has_credentials` uses `grep -q '"id"[[:space:]]*:'`, `grep -q '"secret"[[:space:]]*:'`, and `! grep -q '"provisioningKey"[[:space:]]*:'`.

`add_tag`/`remove_tag` split on `;`, compare exact entries, preserve order, and omit empty entries.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 2 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): add site config and tag helpers"
```

---

### Task 3: TUN config and service backend detection

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `p()`.
- Produces:
  - `ensure_tun_config <conf_path>` → appends missing TUN lines; sets `TUN_CHANGED=0|1`.
  - `backend_from_facts <has_systemd> <has_openrc> <has_supervise>` → stdout `systemd|openrc|none`.
  - `service_backend()` → stdout from real host facts.

- [ ] **Step 1: Write the failing tests**

```bash
conf="$(mktemp)"
TUN_CHANGED=0
ensure_tun_config "$conf"
[[ "$TUN_CHANGED" == "1" ]] || fail "empty conf should change"
grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$conf" || fail "cgroup line"
grep -q 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "$conf" || fail "mount line"

ensure_tun_config "$conf"
[[ "$TUN_CHANGED" == "0" ]] || fail "second pass should be unchanged"
[[ "$(grep -c 'c 10:200' "$conf")" == "1" ]] || fail "no duplicate cgroup line"
rm -f "$conf"

assert_eq systemd "$(backend_from_facts 1 0 0)"
assert_eq openrc "$(backend_from_facts 0 1 1)"
assert_eq none "$(backend_from_facts 0 1 0)"
assert_eq none "$(backend_from_facts 0 0 0)"

echo "Task 3 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `ensure_tun_config: command not found`.

- [ ] **Step 3: Implement the helpers**

`ensure_tun_config` checks both patterns with `grep -qE`, appends only missing lines, and sets `TUN_CHANGED` before returning 0. `service_backend` checks `[[ -d /run/systemd/system ]]`, `command -v rc-service`, and `command -v supervise-daemon`, then calls `backend_from_facts`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 3 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): add TUN and service backend helpers"
```

---

### Task 4: Verified CLI binary install with offline state

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `detect_arch`, `release_version`, `release_digest`, `verify_sha256`, `p()`.
- Produces:
  - `cli_state_matches <version>` → 0 when state file matches and binary hash matches.
  - `write_cli_state <version> <asset> <sha256>` → writes `PANGOLIN_STATE_FILE` mode `0644`.
  - `install_cli_binary <target_version|latest> <pinned_sha|->` → verifies and installs; returns 1 on any failure and leaves the old binary.

- [ ] **Step 1: Write the failing tests**

Create a fake `curl` in a temp bin directory. It prints `API_JSON` for the API URL and copies `FAKE_BINARY` for the release URL, logging each call.

```bash
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/usr/local/bin" "$tmpd/root/var/lib/pangolin"
cat >"$tmpd/pangolin" <<'EOF'
#!/bin/sh
[ "$1" = "version" ] && echo 0.21.0
EOF
chmod 755 "$tmpd/pangolin"
fake_sha="$(sha256sum "$tmpd/pangolin" | awk '{print $1}')"
api="{\"data\":{\"latestVersion\":\"0.21.0\",\"assetDigests\":{\"pangolin-cli_linux_amd64\":\"$fake_sha\"}}}"
cat >"$tmpd/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmpd/curl.log"
case "\$*" in
  *api.fossorial.io*) printf '%s' '$api' ;;
  *releases/download*) cp "$tmpd/pangolin" "\${@: -1}" ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$tmpd/bin/curl"

export PATH="$tmpd/bin:$PATH"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"
export PANGOLIN_STATE_FILE="$tmpd/root/var/lib/pangolin/cli.json"
install_cli_binary latest -
[[ -x "$PANGOLIN_BIN" ]] || fail "binary should install"
[[ "$("$PANGOLIN_BIN" version)" == "0.21.0" ]] || fail "binary version"
cli_state_matches 0.21.0 || fail "state should match"
before="$(wc -l <"$tmpd/curl.log")"
install_cli_binary 0.21.0 -
after="$(wc -l <"$tmpd/curl.log")"
[[ "$before" == "$after" ]] || fail "matching explicit version should skip network"

printf 'old' >"$PANGOLIN_BIN"
if install_cli_binary latest deadbeef >/dev/null 2>&1; then fail "bad digest should fail"; fi
[[ "$(cat "$PANGOLIN_BIN")" == "old" ]] || fail "bad digest must not replace binary"
rm -rf "$tmpd"
unset PANGOLIN_ROOT PANGOLIN_BIN PANGOLIN_STATE_FILE

echo "Task 4 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `install_cli_binary: command not found`.

- [ ] **Step 3: Implement the binary install**

`install_cli_binary`:

1. Refuse a target version below `0.21.0`.
2. If target is `latest`, fetch `PANGOLIN_RELEASE_API` and read `latestVersion`; otherwise use the pinned version.
3. Derive asset `pangolin-cli_linux_$(detect_arch)`.
4. If `cli_state_matches "$version"` returns 0, print a skip message and return 0.
5. Resolve digest: pinned sha when given; otherwise `release_digest` from the API. A pinned version that differs from the API's latest requires `var_pangolin_cli_sha256`; empty digest is an error.
6. Download `PANGOLIN_RELEASE_BASE/$version/$asset` to `mktemp` beside `PANGOLIN_BIN`.
7. `verify_sha256`, `chmod 755`, run `"$tmp" version`, compare with expected version, then `mv`.
8. `write_cli_state`.

Use `curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 120`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 4 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): verify and record the Pangolin CLI binary"
```

---

### Task 5: systemd site install and verification

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `p()`, `site_config_has_credentials`.
- Produces:
  - `wait_service_active <backend> <name> <attempts> <delay>` → 0 when active.
  - `wait_for_provisioning <config_path> <attempts> <delay>` → 0 when credentials exist.
  - `stop_service <backend> <name>`.
  - `install_site_systemd <config_path>` → installs `pangolin-site` and verifies it.

- [ ] **Step 1: Write the failing tests**

Fake `systemctl` returns active for `is-active`, logs all calls, and returns inactivity when `FAKE_INACTIVE=1`. Fake `pangolin` logs its arguments.

```bash
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
cat >"$tmpd/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_LOG"
if [[ "$1" == "is-active" && "${FAKE_INACTIVE:-0}" == "1" ]]; then exit 3; fi
exit 0
EOF
cat >"$tmpd/bin/pangolin" <<'EOF'
#!/usr/bin/env bash
echo "pangolin $*" >>"$FAKE_LOG"
EOF
chmod 755 "$tmpd/bin/systemctl" "$tmpd/bin/pangolin"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_BIN="$tmpd/bin/pangolin"

cfg="$tmpd/site.json"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_systemd "$cfg"
grep -q "service install site --config-file $cfg" "$FAKE_LOG" || fail "site install args"
grep -q "systemctl is-active.*pangolin-site" "$FAKE_LOG" || fail "active check"

if wait_service_active systemd pangolin-site 1 0; then :; else fail "active should pass"; fi
FAKE_INACTIVE=1
if wait_service_active systemd pangolin-site 1 0; then fail "inactive should fail"; fi
stop_service systemd pangolin-site
grep -q "systemctl stop pangolin-site" "$FAKE_LOG" || fail "stop call"

if wait_for_provisioning "$cfg" 1 0; then :; else fail "static credentials should pass"; fi
unset FAKE_INACTIVE
rm -rf "$tmpd"
unset PANGOLIN_BIN FAKE_LOG

echo "Task 5 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `install_site_systemd: command not found`.

- [ ] **Step 3: Implement the systemd site install**

`wait_service_active` loops `attempts` times, calls `systemctl is-active --quiet "$name"` or `rc-service "$name" status`, and sleeps `delay` between attempts.

`wait_for_provisioning` calls `site_config_has_credentials` in the same loop.

`install_site_systemd` runs:

```bash
"$PANGOLIN_BIN" service install site --config-file "$config_path"
wait_service_active systemd pangolin-site 30 1
```

Return 1 if the wait fails; do not print success.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 5 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): install and verify the site service"
```

---

### Task 6: systemd client install

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `wait_service_active`, `PANGOLIN_BIN`.
- Produces: `install_client_systemd <id> <secret> <endpoint>`.

- [ ] **Step 1: Write the failing tests**

Reuse the fake `systemctl` and `pangolin` from Task 5. Append:

```bash
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
# fake systemctl/pangolin identical to Task 5
# ...
export PATH="$tmpd/bin:$PATH" FAKE_LOG="$tmpd/log" PANGOLIN_BIN="$tmpd/bin/pangolin"
install_client_systemd cid csecret "https://p.example"
grep -q "service install client --id cid --secret csecret --endpoint https://p.example" \
  "$FAKE_LOG" || fail "client install args"
grep -q "systemctl is-active.*pangolin-client" "$FAKE_LOG" || fail "client active check"
rm -rf "$tmpd"
unset PANGOLIN_BIN FAKE_LOG

echo "Task 6 tests passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `install_client_systemd: command not found`.

- [ ] **Step 3: Implement the client install**

Run `"$PANGOLIN_BIN" service install client --id "$id" --secret "$secret" --endpoint "$endpoint"`, then `wait_service_active systemd pangolin-client 30 1`. Return 1 when inactive.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 6 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): install and verify the client service"
```

---

### Task 7: OpenRC backends with restart supervision

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `p()`, `wait_service_active`.
- Produces:
  - `write_site_openrc <config_path>` → writes wrapper and `/etc/init.d/pangolin-site`.
  - `write_client_openrc <id> <secret> <endpoint>` → writes env, wrapper, `/etc/init.d/pangolin-client`.
  - `install_site_openrc <config_path>` → writes, enables, starts, verifies.
  - `install_client_openrc <id> <secret> <endpoint>` → writes, enables, starts, verifies.

- [ ] **Step 1: Write the failing tests**

Use `PANGOLIN_ROOT` and fake `rc-update`, `rc-service`, `supervise-daemon`, and `pangolin`.

```bash
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/etc/init.d" "$tmpd/root/usr/local/bin" "$tmpd/root/etc/pangolin" "$tmpd/root/var/log"
for c in rc-update rc-service supervise-daemon pangolin; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
export PATH="$tmpd/bin:$PATH" FAKE_LOG="$tmpd/log" PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"

cfg="$tmpd/root/etc/pangolin/site.json"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_openrc "$cfg"
grep -q 'supervisor=supervise-daemon' "$tmpd/root/etc/init.d/pangolin-site" || fail "site supervisor"
grep -q 'respawn_max=0' "$tmpd/root/etc/init.d/pangolin-site" || fail "site respawn"
grep -q "CONFIG_FILE=$cfg" "$tmpd/root/usr/local/bin/pangolin-site-start" || fail "site config export"
[[ "$(stat -c '%a' "$tmpd/root/usr/local/bin/pangolin-site-start")" == "700" ]] || fail "wrapper mode"

install_client_openrc cid csecret "https://p.example"
grep -q 'supervisor=supervise-daemon' "$tmpd/root/etc/init.d/pangolin-client" || fail "client supervisor"
[[ "$(stat -c '%a' "$tmpd/root/etc/pangolin/pangolin-client.env")" == "600" ]] || fail "client env mode"
grep -q 'rc-service pangolin-client start' "$FAKE_LOG" || fail "client start"
rm -rf "$tmpd"
unset PANGOLIN_ROOT PANGOLIN_BIN FAKE_LOG

echo "Task 7 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `install_site_openrc: command not found`.

- [ ] **Step 3: Implement the OpenRC backends**

Site unit:

```ini
#!/sbin/openrc-run
name="pangolin-site"
description="Pangolin Site (CLI)"
supervisor=supervise-daemon
command="/usr/local/bin/pangolin-site-start"
command_user=root
respawn_delay=2
respawn_max=0
output_log="/var/log/pangolin-site.log"
error_log="/var/log/pangolin-site.log"
depend() { need net; after firewall; }
```

Client unit uses `command="/usr/local/bin/pangolin-client-start"` and client log paths. Wrappers are mode `700`; client env is mode `0600` with `PANGOLIN_CLIENT_ID`, `PANGOLIN_CLIENT_SECRET`, `PANGOLIN_ENDPOINT`. Start with `rc-update add "$name" default` and `rc-service "$name" start`, then `wait_service_active openrc "$name" 30 1`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 7 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): add OpenRC services with restart supervision"
```

---

### Task 8: Backup, restore, and migration

**Files:**
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: `p()`, `write_private_file`, service install functions.
- Produces:
  - `backup_existing <path...>` → stdout backup directory.
  - `restore_backup <backup_dir>` → restores files.
  - `migrate_legacy_newt` → reads `/etc/newt/newt.env` and prepares site credentials when no site config exists.
  - `migrate_existing_addon` → converts old site/client files to the new layout and records what needs cleanup.
  - `cleanup_legacy_addon <site|client|both>` → removes only the old files for components verified in this run.

- [ ] **Step 1: Write the failing tests**

```bash
tmpd="$(mktemp -d)"
export PANGOLIN_ROOT="$tmpd/root"
mkdir -p "$tmpd/root/etc/systemd/system" "$tmpd/root/etc/pangolin" \
  "$tmpd/root/etc/pangolin-cli" "$tmpd/root/etc/newt" "$tmpd/root/var/lib/pangolin"
printf 'UNIT\n' >"$tmpd/root/etc/systemd/system/pangolin-site.service"
printf 'SITE_ID=old\nSITE_SECRET=oldsec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$tmpd/root/etc/pangolin/pangolin-site.env"
printf 'PANGOLIN_CLIENT_ID=cid\nPANGOLIN_CLIENT_SECRET=csec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$tmpd/root/etc/pangolin-cli/client.env"
printf 'NEWT_ID=nid\nNEWT_SECRET=nsec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$tmpd/root/etc/newt/newt.env"

backup="$(backup_existing "$tmpd/root/etc/systemd/system/pangolin-site.service")"
[[ -f "$backup/pangolin-site.service" ]] || fail "backup file"
restore_backup "$backup"
[[ "$(cat "$tmpd/root/etc/systemd/system/pangolin-site.service")" == "UNIT" ]] || fail "restore"

migrate_legacy_newt
[[ "$LEGACY_NEWT_ID" == "nid" ]] || fail "legacy newt id"
[[ "$LEGACY_NEWT_SECRET" == "nsec" ]] || fail "legacy newt secret"
[[ "$LEGACY_ENDPOINT" == "https://p.example" ]] || fail "legacy newt endpoint"

migrate_existing_addon
python3 - "$tmpd/root/etc/pangolin/site.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["id"] == "old", d
assert d["secret"] == "oldsec", d
assert d["endpoint"] == "https://p.example", d
PY
[[ "$(stat -c '%a' "$tmpd/root/etc/pangolin/site.json")" == "600" ]] || fail "migrated mode"
[[ -f "$tmpd/root/etc/pangolin-cli/client.env" ]] || fail "old client env must survive migration"
cleanup_legacy_addon client
[[ ! -f "$tmpd/root/etc/pangolin-cli/client.env" ]] || fail "old client env should be removed after cleanup"
rm -rf "$tmpd"
unset PANGOLIN_ROOT

echo "Task 8 tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: FAIL with `backup_existing: command not found`.

- [ ] **Step 3: Implement backup, restore, and migration**

`backup_existing` creates `$(p /var/lib/pangolin/backup)/<timestamp>` with `mkdir -p`, copies each existing path, and prints the directory. `restore_backup` copies files back with their original names.

`migrate_existing_addon`:

1. Convert old site env to `site.json` only when `site.json` is absent; set `MIGRATED_OLD_SITE=1`.
2. Read old client env and write `/etc/pangolin/pangolin-client.env` mode `0600`; set `MIGRATED_OLD_CLIENT=1`.
3. Do not remove old files here. `cleanup_legacy_addon site|client|both` removes them only after the corresponding component is verified.

`migrate_legacy_newt` reads `/etc/newt/newt.env` and exposes `LEGACY_NEWT_ID`, `LEGACY_NEWT_SECRET`, `LEGACY_ENDPOINT` for the entry point. Do not remove Newt files here.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: `Task 8 tests passed`

- [ ] **Step 5: ShellCheck and commit**

Run: `shellcheck -S error tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh`

```bash
git add tools/addon/lib/pangolin-payload.sh tools/addon/tests/pangolin-addon-test.sh
git commit -m "feat(addon): back up and migrate existing installs"
```

---

### Task 9: Entry validation, payload fetching, and answers directory

**Files:**
- Modify: `tools/addon/add-pangolin.sh` (replace current file)
- Create: `tools/addon/tests/pangolin-addon-entry-test.sh`
- Modify: `tools/addon/lib/pangolin-payload.sh`

**Interfaces:**
- Consumes: payload helpers `site_config_static`, `site_config_provisioning`, `write_private_file`.
- Produces:
  - `validate_endpoint <url>` → 0 for `http://` or `https://` with a host.
  - `validate_site_name <name>` → 0 for 1–63 chars, no control characters.
  - `components_from_mode <mode>` → stdout `SITE CLIENT` (each `0|1`).
  - `fetch_payload <dest>` → downloads `lib/pangolin-payload.sh` or copies `PANGOLIN_PAYLOAD`.
  - `build_site_answers <dir> <endpoint> <provisioning_key|-> <name|-> <id|-> <secret|->`.
  - `build_client_answers <dir> <endpoint> <id> <secret>`.

- [ ] **Step 1: Write the failing entry tests**

Create `tools/addon/tests/pangolin-addon-entry-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PANGOLIN_PAYLOAD="$ROOT/lib/pangolin-payload.sh"
# shellcheck source=../add-pangolin.sh
source "$ROOT/add-pangolin.sh"

assert_eq() { [[ "$1" == "$2" ]] || { echo "FAIL: expected [$2], got [$1]" >&2; exit 1; }; }

validate_endpoint "https://pangolin.example.com" || { echo "https endpoint" >&2; exit 1; }
validate_endpoint "http://127.0.0.1:3002" || { echo "http endpoint" >&2; exit 1; }
if validate_endpoint "pangolin.example.com" >/dev/null 2>&1; then echo "missing scheme should fail" >&2; exit 1; fi
validate_site_name "pve-1" || { echo "site name" >&2; exit 1; }
if validate_site_name "$(printf 'a\nb')" >/dev/null 2>&1; then echo "newline should fail" >&2; exit 1; fi

assert_eq "1 0" "$(components_from_mode site)"
assert_eq "0 1" "$(components_from_mode client)"
assert_eq "1 1" "$(components_from_mode both)"
if components_from_mode nope >/dev/null 2>&1; then echo "bad mode should fail" >&2; exit 1; fi

dir="$(mktemp -d)"
build_site_answers "$dir" "https://p.example" "spk-1.key" "pve-1" - -
[[ -f "$dir/site.json" ]] || { echo "site answers missing" >&2; exit 1; }
python3 - "$dir/site.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provisioningKey"] == "spk-1.key", d
PY
build_client_answers "$dir" "https://p.example" cid csecret
grep -q 'PANGOLIN_CLIENT_ID=cid' "$dir/client.env" || { echo "client answers" >&2; exit 1; }
[[ "$(stat -c '%a' "$dir/client.env")" == "600" ]] || { echo "client env mode" >&2; exit 1; }
rm -rf "$dir"

echo "Entry tests passed"
```

- [ ] **Step 2: Run the entry tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: FAIL because `add-pangolin.sh` has no validation helpers.

- [ ] **Step 3: Replace the entry point**

The new `add-pangolin.sh`:

- Starts with `set -Eeuo pipefail`.
- Defines `REPO_RAW`, `PANGOLIN_PAYLOAD_URL`, `PANGOLIN_TEST` guard.
- Defines the validation and answers helpers above.
- If `PANGOLIN_PAYLOAD` is set and readable, sources it at load time for tests; otherwise `main` fetches it, checks `bash -n`, and sources it.
- Does not run `main` when sourced by the test:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" && "${PANGOLIN_TEST:-0}" != "1" ]]; then
  main "$@"
fi
```

`build_site_answers` writes `site.json` through `write_private_file`; `build_client_answers` writes `client.env` with `PANGOLIN_CLIENT_ID`, `PANGOLIN_CLIENT_SECRET`, `PANGOLIN_ENDPOINT` and mode `0600`.

- [ ] **Step 4: Run the entry tests and ShellCheck**

Run: `bash tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: `Entry tests passed`

Run: `shellcheck -S error tools/addon/add-pangolin.sh tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add tools/addon/add-pangolin.sh tools/addon/tests/pangolin-addon-entry-test.sh
git commit -m "feat(addon): add entry validation and answers builder"
```

---

### Task 10: Entry orchestration, transport, payload main, and partial-result behavior

**Files:**
- Modify: `tools/addon/add-pangolin.sh`
- Modify: `tools/addon/lib/pangolin-payload.sh`
- Modify: `tools/addon/tests/pangolin-addon-entry-test.sh`
- Modify: `tools/addon/tests/pangolin-addon-test.sh`

**Interfaces:**
- Consumes: all prior payload functions; entry helpers.
- Produces:
  - `payload_main <answers_dir>` → installs selected components, returns nonzero on failure.
  - `push_payload <ctid> <payload> <answers_dir>` → uses `pct push` with modes; falls back to `pct exec chmod`.
  - `apply_lxc_tags <ctid> <site> <client>` → exact tag replace.
  - `main` → full interactive/unattended flow.

- [ ] **Step 1: Write the failing tests**

Append to `pangolin-addon-entry-test.sh`:

```bash
# Fake pct and payload for transport/tags
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
cat >"$tmpd/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$FAKE_LOG"
case "$1" in
  config) printf 'tags: old;pangolin-cli\n' ;;
  exec) exit 0 ;;
esac
EOF
chmod 755 "$tmpd/bin/pct"
export PATH="$tmpd/bin:$PATH" FAKE_LOG="$tmpd/log"
printf '#!/bin/sh\n' >"$tmpd/payload.sh"
printf 'flags\n' >"$tmpd/site.json"
push_payload 101 "$tmpd/payload.sh" "$tmpd"
grep -q 'pct push 101' "$FAKE_LOG" || { echo "push missing" >&2; exit 1; }
apply_lxc_tags 101 1 1
grep -q 'pct set 101 -tags' "$FAKE_LOG" || { echo "tags missing" >&2; exit 1; }
grep -q 'pct set 101 -tags old;pangolin-site;pangolin-client' "$FAKE_LOG" || { echo "tag content" >&2; exit 1; }
rm -rf "$tmpd"
unset FAKE_LOG

# Partial result: site succeeds, client fails
tmpd2="$(mktemp -d)"
mkdir -p "$tmpd2/answers"
printf 'SITE=1\nCLIENT=1\n' >"$tmpd2/answers/flags"
write_private_file "$tmpd2/answers/site.json" "$(site_config_static https://p.example id sec)"
write_private_file "$tmpd2/answers/client.env" "PANGOLIN_CLIENT_ID=cid
PANGOLIN_CLIENT_SECRET=csec
PANGOLIN_ENDPOINT=https://p.example"
site_called=0
client_called=0
install_cli_binary() { :; }
service_backend() { echo systemd; }
migrate_existing_addon() { :; }
migrate_legacy_newt() { :; }
cleanup_legacy_addon() { :; }
wait_for_provisioning() { :; }
install_site_systemd() { site_called=1; }
install_client_systemd() { client_called=1; return 1; }
if payload_main "$tmpd2/answers" >/dev/null 2>&1; then echo "partial should fail" >&2; exit 1; fi
[[ "$site_called" == "1" && "$client_called" == "1" ]] || { echo "both components tried" >&2; exit 1; }
rm -rf "$tmpd2"

echo "Orchestration tests passed"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: FAIL with `push_payload: command not found` or `payload_main`.

- [ ] **Step 3: Implement transport, payload main, and orchestration**

`push_payload` uses `pct push "$ctid" "$payload" /root/.pangolin-addon/payload.sh --perms 700` and pushes each answers file with `--perms 600`; on failure, retries without `--perms` and runs `pct exec "$ctid" -- chmod 600 …`.

`apply_lxc_tags` reads `pct config "$ctid" | awk -F': ' '/^tags:/ {print $2}'`, uses `remove_tag` for `pangolin-cli`, `add_tag` for `pangolin-site`/`pangolin-client`, and calls `pct set "$ctid" -tags "$next"` only when changed.

`payload_main`:

1. Reads `flags`; resolves `backend=$(service_backend)` and fails on `none`.
2. Calls `install_cli_binary`.
3. Runs `migrate_existing_addon` and `migrate_legacy_newt` when applicable.
4. Dispatches site to `install_site_systemd` or `install_site_openrc`, verifies provisioning, then calls `cleanup_legacy_addon site`.
5. Dispatches client to `install_client_systemd` or `install_client_openrc`, then calls `cleanup_legacy_addon client`.
6. Returns 1 if a component fails, after stopping that component; leaves earlier successful components running.

`main`:

- Handles `PANGOLIN_DRY_RUN=1` first: validates inputs, prints target/mode/actions, and exits 0 without network, prompts, or filesystem changes.
- Sources core and calls `require_pve_host`.
- Selects mode/target (whiptail or `var_*`).
- Applies TUN for client in LXC using `ensure_tun_config` and graceful `pct shutdown`/`pct start`.
- Builds the answers directory, fetches the payload, and runs it on host or LXC.
- Applies tags, prints service commands, and removes the answers directory in a trap.

- [ ] **Step 4: Run the tests and ShellCheck**

Run: `bash tools/addon/tests/pangolin-addon-test.sh`
Expected: all payload tests pass.

Run: `bash tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: `Entry tests passed` and `Orchestration tests passed`.

Run: `shellcheck -S error tools/addon/add-pangolin.sh tools/addon/lib/pangolin-payload.sh`
Expected: no output.

- [ ] **Step 5: Dry run**

Run:

```bash
PANGOLIN_DRY_RUN=1 var_mode=site var_target=host \
  var_pangolin_endpoint=https://p.example var_site_id=id var_site_secret=sec \
  bash tools/addon/add-pangolin.sh
```

Expected: prints the planned host/site install and exits 0 without changing the system; output contains no `sec`.

Manual check on a paid Pangolin account: create a provisioning key with “approve new sites” off, install site mode with that key, and confirm the site appears `pending` in the dashboard while the addon exits successfully. Confirm a key with approval on creates an active site.

- [ ] **Step 6: Commit**

```bash
git add tools/addon/add-pangolin.sh tools/addon/lib/pangolin-payload.sh \
  tools/addon/tests/pangolin-addon-test.sh tools/addon/tests/pangolin-addon-entry-test.sh
git commit -m "feat(addon): orchestrate host and LXC installs"
```

---

### Task 11: Metadata, CI, and documentation

**Files:**
- Modify: `json/add-pangolin.json`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md` only if the addon description changes

**Interfaces:**
- Consumes: final behavior from Tasks 1–10.
- Produces: user-facing metadata and CI coverage.

- [ ] **Step 1: Update metadata**

Change `config_path` to `/etc/pangolin`. Update notes to cover:

- site provisioning key (tier3/enterprise; dashboard Settings → Provisioning → Keys);
- site ID + secret fallback;
- `pangolin service status|logs|uninstall site|client`;
- binary sha256 verification and optional pinned version/digest;
- Alpine support and OpenRC;
- new unattended variables;
- deprecated update wrappers.

- [ ] **Step 2: Add CI test steps**

In `.github/workflows/ci.yml`, after ShellCheck and `bash -n`, add:

```yaml
      - name: Addon tests
        run: |
          bash tools/addon/tests/pangolin-addon-test.sh
          bash tools/addon/tests/pangolin-addon-entry-test.sh
```

- [ ] **Step 3: Validate**

Run: `python3 -m json.tool json/add-pangolin.json >/dev/null`
Expected: exit 0.

Run: `bash tools/addon/tests/pangolin-addon-test.sh && bash tools/addon/tests/pangolin-addon-entry-test.sh`
Expected: both pass.

- [ ] **Step 4: Commit**

```bash
git add json/add-pangolin.json .github/workflows/ci.yml README.md
git commit -m "docs(addon): document verified Pangolin install paths"
```

---

## Self-Review

Spec coverage:

- Binary trust → Task 4.
- Site provisioning key → Tasks 2, 9, 10.
- Site ID + secret fallback → Tasks 2, 9.
- Upstream systemd service → Tasks 5, 6.
- OpenRC Alpine → Tasks 3, 7.
- TUN idempotency and graceful restart → Task 3, Task 10.
- Secrets and file modes → Tasks 2, 9, 10.
- Verification and failure handling → Tasks 5, 10.
- Migration and backups → Task 8.
- Metadata and CI → Task 11.
- Addon-only scope → Global Constraints; no task touches `ct/` or `install/`.

Review Focus tests:

- JSON special characters → Task 2.
- Same-name backup/restore → Task 8.
- Alpine backend selection → Task 3; respawn manual in Task 7.
- Partial `both` mode → Task 10.
- Provisioning pending state → manual matrix in Task 10; no server-side test.
