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
assert_eq "a;b;c" "$(add_tag "a;b;a" "c")"
assert_eq "x" "$(add_tag "" "x")"
assert_eq "a;b" "$(remove_tag "a;pangolin-cli;b" "pangolin-cli")"
rm -rf "$tmpd"

echo "Task 2 tests passed"

# Task 12: site native interface keys appear only for enabled modes.
# Both enabled matches the documented JSON exactly, including key order.
assert_eq '{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangolin","nativeMain":true,"interfaceMain":"pangolin-main"}' \
  "$(site_config_static "https://p.example" "id" "secret" 1 1 "pangolin" "pangolin-main")"

native_static="$(site_config_static "https://p.example" "id1" "sec1" 1 0 "pangolin" "pangolin")"
python3 - "$native_static" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {
    "endpoint": "https://p.example",
    "id": "id1",
    "secret": "sec1",
    "native": True,
    "interface": "pangolin",
}, d
PY

both_static="$(site_config_static "https://p.example" "id1" "sec1" 1 1 "pangolin" "pangolin-main")"
python3 - "$both_static" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {
    "endpoint": "https://p.example",
    "id": "id1",
    "secret": "sec1",
    "native": True,
    "interface": "pangolin",
    "nativeMain": True,
    "interfaceMain": "pangolin-main",
}, d
PY

native_prov="$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 0 1 "pangolin" "wg-main")"
python3 - "$native_prov" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {
    "endpoint": "https://p.example",
    "provisioningKey": "spk-1.secret",
    "name": "pve-1",
    "nativeMain": True,
    "interfaceMain": "wg-main",
}, d
PY

both_prov="$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 1 1 "pangolin" "pangolin-main")"
python3 - "$both_prov" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d == {
    "endpoint": "https://p.example",
    "provisioningKey": "spk-1.secret",
    "name": "pve-1",
    "native": True,
    "interface": "pangolin",
    "nativeMain": True,
    "interfaceMain": "pangolin-main",
}, d
PY

# Disabled modes add no native keys, even when interface names are supplied.
assert_eq "$static" "$(site_config_static "https://p.example" "id1" "sec1" 0 0 "wg0" "wg1")"
assert_eq "$prov" "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 0 0 "wg0" "wg1")"

echo "Task 12 tests passed"

conf="$(mktemp)"
TUN_CHANGED=0
ensure_tun_config "$conf"
[[ "$TUN_CHANGED" == "1" ]] || fail "empty conf should change"
grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$conf" || fail "cgroup line"
grep -q 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "$conf" || fail "mount line"

ensure_tun_config "$conf"
[[ "$TUN_CHANGED" == "0" ]] || fail "second pass should be unchanged"
[[ "$(grep -c 'c 10:200' "$conf")" == "1" ]] || fail "no duplicate cgroup line"
[[ "$(grep -c 'lxc.mount.entry: /dev/net/tun' "$conf")" == "1" ]] || fail "no duplicate mount line"
rm -f "$conf"

# A last line without a trailing newline must not merge with the appended lines.
conf="$(mktemp)"
printf 'arch: amd64' >"$conf"
TUN_CHANGED=0
ensure_tun_config "$conf" || fail "unterminated last line should still succeed"
assert_eq "$(grep -c '^arch: amd64$' "$conf")" 1
grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$conf" || fail "cgroup line after unterminated last line"
grep -q 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "$conf" ||
  fail "mount line after unterminated last line"
rm -f "$conf"

# Spaced variants count as present and are not duplicated.
conf="$(mktemp)"
printf 'lxc.cgroup2.devices.allow:   c 10:200 rwm\n' >"$conf"
ensure_tun_config "$conf" || fail "spaced cgroup line should still succeed"
assert_eq "$(grep -c 'c 10:200' "$conf")" 1
rm -f "$conf"

# A write to an unusable path must fail instead of claiming success.
missing="$(mktemp -d)/no-such-dir/lxc.conf"
TUN_CHANGED=0
if ensure_tun_config "$missing" >/dev/null 2>&1; then
  fail "missing parent directory should fail"
fi
[[ ! -e "$missing" ]] || fail "failed write should not create the file"
rm -rf "$(dirname "$(dirname "$missing")")"

assert_eq systemd "$(backend_from_facts 1 0 0)"
assert_eq openrc "$(backend_from_facts 0 1 1)"
assert_eq none "$(backend_from_facts 0 1 0)"
assert_eq none "$(backend_from_facts 0 0 0)"

case "$(service_backend)" in
systemd | openrc | none) ;;
*) fail "service_backend returned unexpected value" ;;
esac

echo "Task 3 tests passed"

# Task 4: verified CLI binary install with offline state.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/usr/local/bin" "$tmpd/root/var/lib/pangolin"
cat >"$tmpd/pangolin" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
  echo "Pangolin desktop client banner"
  echo
  echo "0.21.0"
fi
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

old_path="$PATH"
old_pangolin_root="$PANGOLIN_ROOT"
old_pangolin_bin="$PANGOLIN_BIN"
old_pangolin_state_file="$PANGOLIN_STATE_FILE"
old_pangolin_selinux_enforce="$PANGOLIN_SELINUX_ENFORCE"
export PATH="$tmpd/bin:$PATH"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"
export PANGOLIN_STATE_FILE="$tmpd/root/var/lib/pangolin/cli.json"
# Keep the install tests hermetic: no SELinux context restore by default.
export PANGOLIN_SELINUX_ENFORCE="$tmpd/no-selinux"
install_cli_binary latest -
[[ -x "$PANGOLIN_BIN" ]] || fail "binary should install"
[[ "$("$PANGOLIN_BIN" version | tail -n1)" == "0.21.0" ]] || fail "binary version"
cli_state_matches 0.21.0 || fail "state should match"
[[ "$(stat -c '%a' "$PANGOLIN_STATE_FILE")" == "644" ]] || fail "state file mode"
grep -q '"version":"0.21.0"' "$PANGOLIN_STATE_FILE" || fail "state version"
grep -q "\"sha256\":\"$fake_sha\"" "$PANGOLIN_STATE_FILE" || fail "state digest"
before="$(wc -l <"$tmpd/curl.log")"
install_cli_binary 0.21.0 -
after="$(wc -l <"$tmpd/curl.log")"
[[ "$before" == "$after" ]] || fail "matching explicit version should skip network"

# A version below the 0.21.0 floor is refused before any download.
if install_cli_binary 0.20.9 - >/dev/null 2>&1; then fail "version below floor should fail"; fi
# A pinned version that is not the API's latest needs an explicit digest.
if install_cli_binary 0.21.1 - >/dev/null 2>&1; then fail "pinned version needs explicit digest"; fi
[[ "$("$PANGOLIN_BIN" version | tail -n1)" == "0.21.0" ]] || fail "refused install must keep the binary"

printf 'old' >"$PANGOLIN_BIN"
if install_cli_binary latest deadbeef >/dev/null 2>&1; then fail "bad digest should fail"; fi
[[ "$(cat "$PANGOLIN_BIN")" == "old" ]] || fail "bad digest must not replace binary"

# A state write failure after verification must not replace the binary either.
# Fail only the state-file temp creation; the download temp still works.
# shellcheck disable=SC2317
mktemp() {
  case "${1:-}" in
  *.cli.json.XXXXXX) return 1 ;;
  esac
  command mktemp "$@"
}
if state_err="$(install_cli_binary latest "$fake_sha" 2>&1 >/dev/null)"; then
  unset -f mktemp
  fail "failed state write should fail"
fi
unset -f mktemp
case "$state_err" in
*"failed to write"*) ;;
*) fail "expected a state write failure, got: $state_err" ;;
esac
[[ "$(cat "$PANGOLIN_BIN")" == "old" ]] || fail "failed state write must not replace binary"

# SELinux context restore: an enforce file plus restorecon calls it with the path.
enforce_file="$tmpd/selinux-enforce"
: >"$enforce_file"
cat >"$tmpd/bin/restorecon" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmpd/restorecon.log"
EOF
chmod 755 "$tmpd/bin/restorecon"
export PANGOLIN_SELINUX_ENFORCE="$enforce_file"
restore_selinux_context "$PANGOLIN_BIN" || fail "restore_selinux_context should succeed"
[[ "$(cat "$tmpd/restorecon.log")" == "$PANGOLIN_BIN" ]] ||
  fail "restorecon should receive the binary path"
rm -f "$tmpd/restorecon.log"

# Missing restorecon only warns; it must not fail.
mkdir -p "$tmpd/empty-bin"
if ! warning="$(PATH="$tmpd/empty-bin" restore_selinux_context "$PANGOLIN_BIN" 2>&1)"; then
  fail "missing restorecon should not fail"
fi
case "$warning" in
*restorecon*) ;;
*) fail "missing restorecon should warn" ;;
esac

# Without an enforce file the helper does nothing.
export PANGOLIN_SELINUX_ENFORCE="$tmpd/no-selinux"
restore_selinux_context "$PANGOLIN_BIN" || fail "no SELinux should succeed"
[[ ! -e "$tmpd/restorecon.log" ]] || fail "no enforce file should skip restorecon"

# The install path restores the context after moving the verified binary.
rm -f "$PANGOLIN_BIN" "$PANGOLIN_STATE_FILE"
export PANGOLIN_SELINUX_ENFORCE="$enforce_file"
install_cli_binary latest -
[[ "$(cat "$tmpd/restorecon.log")" == "$PANGOLIN_BIN" ]] ||
  fail "install should restore the binary's SELinux context"

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
export PANGOLIN_STATE_FILE="$old_pangolin_state_file"
export PANGOLIN_SELINUX_ENFORCE="$old_pangolin_selinux_enforce"

echo "Task 4 tests passed"

# Task 5: systemd site install and shared wait/stop helpers.
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

old_path="$PATH"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
old_fake_inactive="${FAKE_INACTIVE:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_BIN="$tmpd/bin/pangolin"

cfg="$tmpd/site.json"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_systemd "$cfg"
grep -q "service install site --config-file $cfg" "$FAKE_LOG" || fail "site install args"
grep -q "systemctl is-active.*pangolin-site" "$FAKE_LOG" || fail "active check"

# An already-active unit is restarted before the active wait so new
# configuration takes effect. A fresh install is not restarted.
: >"$FAKE_LOG"
install_site_systemd "$cfg" 1 || fail "active site reinstall should succeed"
grep -q "systemctl restart pangolin-site" "$FAKE_LOG" || fail "active site should restart"
restart_line="$(grep -n "systemctl restart pangolin-site" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
active_line="$(grep -n "systemctl is-active.*pangolin-site" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ "$restart_line" -lt "$active_line" ]] || fail "site restart must precede the active wait"
: >"$FAKE_LOG"
install_site_systemd "$cfg"
if grep -q "systemctl restart pangolin-site" "$FAKE_LOG"; then
  fail "fresh site install must not restart"
fi

if wait_service_active systemd pangolin-site 1 0; then :; else fail "active should pass"; fi
export FAKE_INACTIVE=1
if wait_service_active systemd pangolin-site 1 0; then fail "inactive should fail"; fi
unset FAKE_INACTIVE
stop_service systemd pangolin-site
grep -q "systemctl stop pangolin-site" "$FAKE_LOG" || fail "stop call"

if wait_for_provisioning "$cfg" 1 0; then :; else fail "static credentials should pass"; fi
prov_cfg="$tmpd/prov.json"
write_private_file "$prov_cfg" "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
if wait_for_provisioning "$prov_cfg" 1 0; then
  fail "a provisioning key should not count as credentials"
fi

# Leading-zero attempt counts must be read as decimal, not rejected as bad
# octal or misread as fewer attempts.
if ! noise="$(wait_service_active systemd pangolin-site 08 0 2>&1)"; then
  fail "leading-zero attempts should pass"
fi
[[ -z "$noise" ]] || fail "leading-zero attempts printed: $noise"
if ! noise="$(wait_for_provisioning "$cfg" 08 0 2>&1)"; then
  fail "leading-zero provisioning attempts should pass"
fi
[[ -z "$noise" ]] || fail "leading-zero provisioning attempts printed: $noise"

# A site install that never activates must fail and must not report success.
# Shadow the wait helper in a subshell so the real one stays available later.
site_rc=0
site_stdout="$(
  wait_service_active() { return 1; }
  install_site_systemd "$cfg" 2>/dev/null
)" || site_rc=$?
[[ "$site_rc" -ne 0 ]] || fail "inactive install should fail"
[[ -z "$site_stdout" ]] || fail "inactive install should not report success"

# A failing CLI install must fail without waiting for the service.
cat >"$tmpd/bin/pangolin-fail" <<'EOF'
#!/usr/bin/env bash
echo "pangolin $*" >>"$FAKE_LOG"
exit 1
EOF
chmod 755 "$tmpd/bin/pangolin-fail"
install_rc=0
install_stdout="$(
  export PANGOLIN_BIN="$tmpd/bin/pangolin-fail"
  install_site_systemd "$cfg" 2>/dev/null
)" || install_rc=$?
[[ "$install_rc" -ne 0 ]] || fail "failed CLI install should fail"
[[ -z "$install_stdout" ]] || fail "failed CLI install should not report success"

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
if [[ -n "$old_fake_inactive" ]]; then export FAKE_INACTIVE="$old_fake_inactive"; else unset FAKE_INACTIVE; fi

echo "Task 5 tests passed"

# Task 6: systemd client install.
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

old_path="$PATH"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
old_fake_inactive="${FAKE_INACTIVE:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_BIN="$tmpd/bin/pangolin"

client_stdout="$(install_client_systemd cid csecret "https://p.example")" ||
  fail "client install should succeed"
[[ -z "$client_stdout" ]] || fail "client install should stay quiet on success"
grep -q "service install client --id cid --secret csecret --endpoint https://p.example" \
  "$FAKE_LOG" || fail "client install args"
grep -q "systemctl is-active.*pangolin-client" "$FAKE_LOG" || fail "client active check"

# Replacing an active client restarts it so new credentials take effect; a
# fresh client install is not restarted.
: >"$FAKE_LOG"
install_client_systemd cid csecret "https://p.example" 1 ||
  fail "active client reinstall should succeed"
grep -q "systemctl restart pangolin-client" "$FAKE_LOG" || fail "active client should restart"
: >"$FAKE_LOG"
install_client_systemd cid csecret "https://p.example"
if grep -q "systemctl restart pangolin-client" "$FAKE_LOG"; then
  fail "fresh client install must not restart"
fi

# A client install that never activates must fail and must not report success.
client_rc=0
client_stdout="$(
  wait_service_active() { return 1; }
  install_client_systemd cid csecret "https://p.example" 2>/dev/null
)" || client_rc=$?
[[ "$client_rc" -ne 0 ]] || fail "inactive client install should fail"
[[ -z "$client_stdout" ]] || fail "inactive client install should not report success"
case "$client_stdout" in
*"csecret"*) fail "client install must not print the secret" ;;
esac

# A failing CLI install must fail without waiting for the service.
cat >"$tmpd/bin/pangolin-fail" <<'EOF'
#!/usr/bin/env bash
echo "pangolin $*" >>"$FAKE_LOG"
exit 1
EOF
chmod 755 "$tmpd/bin/pangolin-fail"
client_rc=0
client_stdout="$(
  export PANGOLIN_BIN="$tmpd/bin/pangolin-fail"
  install_client_systemd cid csecret "https://p.example" 2>/dev/null
)" || client_rc=$?
[[ "$client_rc" -ne 0 ]] || fail "failed client CLI install should fail"
[[ -z "$client_stdout" ]] || fail "failed client CLI install should not report success"

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
if [[ -n "$old_fake_inactive" ]]; then export FAKE_INACTIVE="$old_fake_inactive"; else unset FAKE_INACTIVE; fi

echo "Task 6 tests passed"

# Task 7: OpenRC site and client installs with restart supervision.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/etc/init.d" "$tmpd/root/usr/local/bin" \
  "$tmpd/root/etc/pangolin" "$tmpd/root/var/log"
for c in rc-update rc-service supervise-daemon pangolin logrotate; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
# Record the exported CONFIG_FILE and the argv of every wrapper exec.
cat >"$tmpd/root/usr/local/bin/pangolin" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >>"$FAKE_LOG"
printf 'CONFIG_FILE=%s\n' "${CONFIG_FILE:-}" >>"$FAKE_LOG"
printf 'PANGOLIN_CLIENT_SECRET=%s\n' "${PANGOLIN_CLIENT_SECRET:-}" >>"$FAKE_LOG"
EOF
chmod 755 "$tmpd/root/usr/local/bin/pangolin"

old_path="$PATH"
old_pangolin_root="$PANGOLIN_ROOT"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"

site_unit="$tmpd/root/etc/init.d/pangolin-site"
site_wrapper="$tmpd/root/usr/local/bin/pangolin-site-start"
cfg="$tmpd/root/etc/pangolin/site.json"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_openrc "$cfg"
grep -q 'supervisor=supervise-daemon' "$site_unit" || fail "site supervisor"
grep -q 'respawn_max=0' "$site_unit" || fail "site respawn"
grep -q 'respawn_delay=2' "$site_unit" || fail "site respawn delay"
grep -q 'command_user=root' "$site_unit" || fail "site command user"
grep -q 'need net' "$site_unit" || fail "site net dependency"
grep -q "command=\"$site_wrapper\"" "$site_unit" || fail "site unit command"
grep -q "CONFIG_FILE=$cfg" "$site_wrapper" || fail "site config export"
grep -q 'exec .*pangolin.* up site' "$site_wrapper" || fail "site wrapper exec"
[[ "$(stat -c '%a' "$site_wrapper")" == "700" ]] || fail "wrapper mode"
[[ "$(stat -c '%a' "$site_unit")" == "755" ]] || fail "site unit mode"
grep -q 'rc-update add pangolin-site default' "$FAKE_LOG" || fail "site enable"
grep -q 'rc-service pangolin-site start' "$FAKE_LOG" || fail "site start"
grep -q 'rc-service pangolin-site status' "$FAKE_LOG" || fail "site status check"
# An already-active OpenRC service is restarted so new configuration applies.
: >"$FAKE_LOG"
install_site_openrc "$cfg" 1 || fail "active site reinstall should succeed"
grep -q 'rc-service pangolin-site restart' "$FAKE_LOG" || fail "active site should restart"
: >"$FAKE_LOG"
install_site_openrc "$cfg"
if grep -q 'rc-service pangolin-site restart' "$FAKE_LOG"; then
  fail "fresh OpenRC site install must not restart"
fi
# Run the wrapper: CONFIG_FILE must reach the CLI exported and intact.
"$site_wrapper" || fail "site wrapper should run"
grep -q "^CONFIG_FILE=$cfg$" "$FAKE_LOG" || fail "site wrapper must export CONFIG_FILE"
grep -q '^argv=up site$' "$FAKE_LOG" || fail "site wrapper argv"

client_unit="$tmpd/root/etc/init.d/pangolin-client"
client_wrapper="$tmpd/root/usr/local/bin/pangolin-client-start"
client_env="$tmpd/root/etc/pangolin/pangolin-client.env"
install_client_openrc cid csecret "https://p.example"
grep -q 'supervisor=supervise-daemon' "$client_unit" || fail "client supervisor"
grep -q 'respawn_max=0' "$client_unit" || fail "client respawn"
grep -q "command=\"$client_wrapper\"" "$client_unit" || fail "client unit command"
[[ "$(stat -c '%a' "$client_env")" == "600" ]] || fail "client env mode"
[[ "$(stat -c '%a' "$client_wrapper")" == "700" ]] || fail "client wrapper mode"
grep -q "^PANGOLIN_CLIENT_ID='cid'$" "$client_env" || fail "client id env"
grep -q "^PANGOLIN_CLIENT_SECRET='csecret'$" "$client_env" || fail "client secret env"
grep -q "^PANGOLIN_ENDPOINT='https://p.example'$" "$client_env" || fail "client endpoint env"
grep -q 'rc-update add pangolin-client default' "$FAKE_LOG" || fail "client enable"
grep -q 'rc-service pangolin-client start' "$FAKE_LOG" || fail "client start"
grep -q 'rc-service pangolin-client status' "$FAKE_LOG" || fail "client status check"
# An already-active client is restarted so new credentials take effect.
: >"$FAKE_LOG"
install_client_openrc cid csecret "https://p.example" 1 ||
  fail "active client reinstall should succeed"
grep -q 'rc-service pangolin-client restart' "$FAKE_LOG" || fail "active client should restart"
: >"$FAKE_LOG"
install_client_openrc cid csecret "https://p.example"
if grep -q 'rc-service pangolin-client restart' "$FAKE_LOG"; then
  fail "fresh OpenRC client install must not restart"
fi
if grep -q 'csecret' "$client_unit" "$client_wrapper"; then
  fail "client unit and wrapper must not contain the secret"
fi
# logrotate is installed for both OpenRC log paths when it is available.
lr="$tmpd/root/etc/logrotate.d/pangolin"
[[ -f "$lr" ]] || fail "logrotate config should be written"
[[ "$(stat -c '%a' "$lr")" == "644" ]] || fail "logrotate config mode"
for token in copytruncate size rotate compress missingok notifempty; do
  grep -q "$token" "$lr" || fail "logrotate config missing $token"
done
grep -q "$tmpd/root/var/log/pangolin-site.log" "$lr" || fail "logrotate site log path"
grep -q "$tmpd/root/var/log/pangolin-client.log" "$lr" || fail "logrotate client log path"
# Run the wrapper: the sourced env must reach the CLI, but not through argv.
"$client_wrapper" || fail "client wrapper should run"
grep -q '^PANGOLIN_CLIENT_SECRET=csecret$' "$FAKE_LOG" ||
  fail "client wrapper must export PANGOLIN_CLIENT_SECRET"
grep -q '^argv=up client --attach$' "$FAKE_LOG" || fail "client wrapper argv"
if grep -q '^argv=.*csecret' "$FAKE_LOG"; then
  fail "client wrapper must not pass the secret in argv"
fi

# Shell metacharacters in credentials must reach the CLI verbatim, not run.
hostile="s3cr\$et \`id\` 'q' ; \"d\""
write_client_openrc hid "$hostile" "https://p.example"
"$client_wrapper" || fail "client wrapper with hostile secret should run"
grep -qF "PANGOLIN_CLIENT_SECRET=$hostile" "$FAKE_LOG" ||
  fail "client env must preserve shell metacharacters verbatim"

# Without supervise-daemon the unit cannot restart, so writing must refuse.
mkdir -p "$tmpd/no-supervise"
if supervise_err="$(PATH="$tmpd/no-supervise:/usr/bin:/bin" write_site_openrc "$cfg" 2>&1 >/dev/null)"; then
  fail "missing supervise-daemon should fail"
fi
case "$supervise_err" in
*supervise-daemon*) ;;
*) fail "missing supervise-daemon should name it, got: $supervise_err" ;;
esac

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi

echo "Task 7 tests passed"

# Task 8: backups, restore, and migration of existing addon installs.
tmpd="$(mktemp -d)"
old_pangolin_root="$PANGOLIN_ROOT"
export PANGOLIN_ROOT="$tmpd/root"
mkdir -p "$tmpd/root/etc/systemd/system" "$tmpd/root/etc/pangolin" \
  "$tmpd/root/etc/pangolin-cli" "$tmpd/root/etc/newt" "$tmpd/root/etc/init.d" \
  "$tmpd/root/usr/local/bin" "$tmpd/root/usr/bin" "$tmpd/root/root" \
  "$tmpd/root/var/lib/pangolin"
site_unit="$tmpd/root/etc/systemd/system/pangolin-site.service"
old_site_env="$tmpd/root/etc/pangolin/pangolin-site.env"
old_client_env="$tmpd/root/etc/pangolin-cli/client.env"
new_client_env="$tmpd/root/etc/pangolin/pangolin-client.env"
new_site_json="$tmpd/root/etc/pangolin/site.json"
newt_env="$tmpd/root/etc/newt/newt.env"
old_client_unit="$tmpd/root/etc/systemd/system/pangolin-cli.service"
old_client_wrapper="$tmpd/root/usr/local/bin/pangolin-cli-start"
old_client_init="$tmpd/root/etc/init.d/pangolin-cli"
old_site_wrapper="$tmpd/root/usr/local/bin/pangolin-site-start"
legacy_marker="$tmpd/root/root/.pangolin-cli"
old_site_updater="$tmpd/root/usr/bin/update-pangolin-site"
old_client_updater="$tmpd/root/usr/bin/update-pangolin-cli"

printf 'UNIT\n' >"$site_unit"
printf 'SITE_ID=old\nSITE_SECRET=oldsec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$old_site_env"
chmod 600 "$old_site_env"
printf 'PANGOLIN_CLIENT_ID=cid\nPANGOLIN_CLIENT_SECRET=csec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$old_client_env"
chmod 600 "$old_client_env"
printf 'NEWT_ID=nid\nNEWT_SECRET=nsec\nPANGOLIN_ENDPOINT=https://p.example\n' >"$newt_env"
printf '[Unit]\n' >"$old_client_unit"
printf '#!/bin/sh\n. /etc/pangolin-cli/client.env\nexec pangolin --attach\n' \
  >"$old_client_wrapper"
printf '#!/sbin/openrc-run\n' >"$old_client_init"
printf '#!/bin/sh\n. /etc/pangolin/pangolin-site.env\nexec pangolin up site\n' \
  >"$old_site_wrapper"
printf '1.2.3\n' >"$legacy_marker"
printf '#!/bin/sh\nexec old-site-updater\n' >"$old_site_updater"
chmod 755 "$old_site_updater"
printf '#!/bin/sh\nexec old-client-updater\n' >"$old_client_updater"
chmod 755 "$old_client_updater"

backup="$(backup_existing "$site_unit" "$old_site_env")"
[[ -f "$backup/pangolin-site.service" ]] || fail "backup file"
[[ -f "$backup/pangolin-site.env" ]] || fail "backup env file"
case "$backup" in
"$tmpd/root/var/lib/pangolin/backup/"*) ;;
*) fail "backup should live under the state directory, got: $backup" ;;
esac
[[ "$(stat -c '%a' "$backup")" == "700" ]] || fail "backup directory mode"
[[ "$(stat -c '%a' "$backup/pangolin-site.env")" == "600" ]] || fail "backup secret mode"
backup2="$(backup_existing "$tmpd/root/no-such-file")"
[[ "$backup2" != "$backup" ]] || fail "each backup should get its own directory"
[[ ! -e "$backup2/no-such-file" ]] || fail "missing paths must not be backed up"

printf 'CHANGED\n' >"$site_unit"
chmod 644 "$old_site_env"
restore_backup "$backup"
[[ "$(cat "$site_unit")" == "UNIT" ]] || fail "restore"
[[ "$(stat -c '%a' "$old_site_env")" == "600" ]] || fail "restore should keep the original mode"

# A corrupt manifest must fail before restoring any valid earlier line.
cp -a "$backup" "$tmpd/corrupt-backup"
printf 'garbage\n' >>"$tmpd/corrupt-backup/manifest"
printf 'STILL-CHANGED\n' >"$site_unit"
if restore_backup "$tmpd/corrupt-backup" >/dev/null 2>&1; then
  fail "a corrupt manifest should fail"
fi
[[ "$(cat "$site_unit")" == "STILL-CHANGED" ]] ||
  fail "a corrupt manifest must not partially restore"
restore_backup "$backup" || fail "restore after a corrupt manifest should work"

if restore_backup "$tmpd/not-a-backup" >/dev/null 2>&1; then
  fail "restoring a directory that is not a backup should fail"
fi

LEGACY_NEWT_ID=""
LEGACY_NEWT_SECRET=""
LEGACY_ENDPOINT=""
migrate_legacy_newt
assert_eq "$LEGACY_NEWT_ID" "nid"
assert_eq "$LEGACY_NEWT_SECRET" "nsec"
assert_eq "$LEGACY_ENDPOINT" "https://p.example"
[[ ! -e "$new_site_json" ]] || fail "legacy Newt migration must not write the site config"
[[ -f "$newt_env" ]] || fail "legacy Newt migration must not remove the Newt env"

migrate_existing_addon >"$tmpd/migrate.log" 2>&1
assert_eq "$MIGRATED_OLD_SITE" "1"
assert_eq "$MIGRATED_OLD_CLIENT" "1"
python3 - "$new_site_json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["id"] == "old", d
assert d["secret"] == "oldsec", d
assert d["endpoint"] == "https://p.example", d
PY
[[ "$(stat -c '%a' "$new_site_json")" == "600" ]] || fail "migrated mode"
[[ -f "$old_site_env" ]] || fail "old site env must survive migration"
[[ -f "$old_client_env" ]] || fail "old client env must survive migration"
[[ -f "$new_client_env" ]] || fail "new client env should be written"
[[ "$(stat -c '%a' "$new_client_env")" == "600" ]] || fail "new client env mode"
grep -q "^PANGOLIN_CLIENT_ID='cid'$" "$new_client_env" || fail "migrated client id"
grep -q "^PANGOLIN_CLIENT_SECRET='csec'$" "$new_client_env" || fail "migrated client secret"
grep -q "^PANGOLIN_ENDPOINT='https://p.example'$" "$new_client_env" ||
  fail "migrated client endpoint"
for secret in oldsec csec nsec; do
  if grep -q "$secret" "$tmpd/migrate.log"; then
    fail "migration must not print the secret $secret"
  fi
done

# An existing site config wins over the old env file.
original_site="$(cat "$new_site_json")"
write_private_file "$new_site_json" \
  "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
migrate_existing_addon >/dev/null 2>&1
assert_eq "$MIGRATED_OLD_SITE" "0"
grep -q '"provisioningKey"' "$new_site_json" ||
  fail "migration must not overwrite an existing site config"
write_private_file "$new_site_json" "$original_site"

# An existing client env also wins over the old client file.
original_client="$(cat "$new_client_env")"
write_private_file "$new_client_env" "PANGOLIN_CLIENT_ID='newid'"
migrate_existing_addon >/dev/null 2>&1
assert_eq "$MIGRATED_OLD_CLIENT" "0"
grep -q "^PANGOLIN_CLIENT_ID='newid'$" "$new_client_env" ||
  fail "migration must not overwrite an existing client env"
write_private_file "$new_client_env" "$original_client"

if cleanup_legacy_addon bogus >/dev/null 2>&1; then
  fail "an unknown cleanup scope should fail"
fi
[[ -f "$old_site_env" && -f "$old_client_env" ]] ||
  fail "an invalid cleanup scope must not remove files"

cleanup_legacy_addon client
[[ ! -f "$old_client_env" ]] || fail "old client env should be removed after cleanup"
[[ ! -f "$old_client_unit" ]] || fail "old client unit should be removed after cleanup"
[[ ! -f "$old_client_wrapper" ]] || fail "old client wrapper should be removed after cleanup"
[[ ! -f "$old_client_init" ]] || fail "old client init script should be removed after cleanup"
[[ ! -d "$tmpd/root/etc/pangolin-cli" ]] || fail "old client directory should be removed"
[[ ! -e "$legacy_marker" ]] || fail "legacy binary marker should be removed"
[[ -f "$old_site_env" ]] || fail "client cleanup must not remove site files"
[[ -f "$new_client_env" ]] || fail "cleanup must keep the new client env"
[[ -f "$new_site_json" ]] || fail "cleanup must keep the new site config"
[[ -n "$LEGACY_CLIENT_BACKUP_DIR" ]] || fail "client cleanup should create a backup"
[[ -f "$LEGACY_CLIENT_BACKUP_DIR/client.env" ]] ||
  fail "client cleanup backup must keep the legacy client env"
grep -q '^PANGOLIN_CLIENT_SECRET=csec$' "$LEGACY_CLIENT_BACKUP_DIR/client.env" ||
  fail "client cleanup backup must keep the legacy secret"
[[ "$(stat -c '%a' "$LEGACY_CLIENT_BACKUP_DIR/client.env")" == "600" ]] ||
  fail "client cleanup backup must keep the secret mode"
# The old generated client updater is replaced by the safe CLI wrapper, and
# its original content is preserved in the cleanup backup.
grep -q 'exec /usr/local/bin/pangolin update' "$old_client_updater" ||
  fail "client updater should become the pangolin update wrapper"
[[ -x "$old_client_updater" ]] || fail "client updater wrapper should be executable"
grep -q 'old-client-updater' "$LEGACY_CLIENT_BACKUP_DIR/update-pangolin-cli" ||
  fail "client cleanup backup must keep the old updater"

cleanup_legacy_addon site
[[ ! -f "$old_site_env" ]] || fail "old site env should be removed after cleanup"
[[ ! -f "$old_site_wrapper" ]] || fail "old site wrapper should be removed after cleanup"
[[ -f "$new_client_env" ]] || fail "site cleanup must not remove client files"
[[ -f "$new_site_json" ]] || fail "site cleanup must keep the new site config"
[[ -n "$LEGACY_SITE_BACKUP_DIR" ]] || fail "site cleanup should create a backup"
[[ -f "$LEGACY_SITE_BACKUP_DIR/pangolin-site.env" ]] ||
  fail "site cleanup backup must keep the legacy site env"
grep -q '^SITE_SECRET=oldsec$' "$LEGACY_SITE_BACKUP_DIR/pangolin-site.env" ||
  fail "site cleanup backup must keep the legacy secret"
[[ "$(stat -c '%a' "$LEGACY_SITE_BACKUP_DIR/pangolin-site.env")" == "600" ]] ||
  fail "site cleanup backup must keep the secret mode"
# The old generated site updater is replaced by the safe CLI wrapper, and its
# original content is preserved in the cleanup backup.
grep -q 'exec /usr/local/bin/pangolin update' "$old_site_updater" ||
  fail "site updater should become the pangolin update wrapper"
[[ -x "$old_site_updater" ]] || fail "site updater wrapper should be executable"
grep -q 'old-site-updater' "$LEGACY_SITE_BACKUP_DIR/update-pangolin-site" ||
  fail "site cleanup backup must keep the old updater"

# The current OpenRC site wrapper must survive a repeated cleanup.
printf '#!/bin/sh\nCONFIG_FILE=%s\nexport CONFIG_FILE\n' "$new_site_json" \
  >"$old_site_wrapper"
cleanup_legacy_addon site
[[ -f "$old_site_wrapper" ]] || fail "cleanup must keep the current site wrapper"

# The upstream CLI writes its own env at the legacy path. Migration records the
# old format before install, but cleanup must keep the CONFIG_FILE form.
printf 'SITE_ID=old\nSITE_SECRET=oldsec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$old_site_env"
migrate_existing_addon >/dev/null 2>&1
printf 'CONFIG_FILE=%s\n' "$new_site_json" >"$old_site_env"
cleanup_legacy_addon site >/dev/null 2>&1 ||
  fail "cleanup after upstream env replacement should succeed"
[[ -f "$old_site_env" ]] || fail "upstream CONFIG_FILE env must survive cleanup"
grep -q '^CONFIG_FILE=' "$old_site_env" || fail "upstream env contents must survive"
[[ -f "$new_site_json" ]] || fail "upstream env cleanup must keep the site config"

# An upstream env present before migration is not recorded as legacy at all.
rm -f "$old_site_env"
printf 'CONFIG_FILE=%s\n' "$new_site_json" >"$old_site_env"
_record_legacy_paths
for path in "${LEGACY_SITE_FILES[@]}"; do
  [[ "$path" != "$old_site_env" ]] ||
    fail "an upstream CONFIG_FILE env must not be recorded as legacy"
done

# A later migration plus both-scope cleanup removes both components' old files.
mkdir -p "$tmpd/root/etc/pangolin-cli"
printf 'SITE_ID=old\nSITE_SECRET=oldsec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$old_site_env"
printf 'PANGOLIN_CLIENT_ID=cid\nPANGOLIN_CLIENT_SECRET=csec\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$old_client_env"
migrate_existing_addon >/dev/null 2>&1
cleanup_legacy_addon both
[[ ! -f "$old_site_env" && ! -f "$old_client_env" ]] ||
  fail "both-scope cleanup should remove both old files"

# Migration on a fresh root is a quiet no-op.
mkdir -p "$tmpd/empty/root/etc/pangolin"
export PANGOLIN_ROOT="$tmpd/empty/root"
if ! noise="$(migrate_existing_addon 2>&1)"; then
  fail "migration on a fresh root should succeed"
fi
[[ -z "$noise" ]] || fail "migration on a fresh root printed: $noise"
assert_eq "$MIGRATED_OLD_SITE" "0"
assert_eq "$MIGRATED_OLD_CLIENT" "0"
[[ ! -e "$tmpd/empty/root/etc/pangolin/site.json" ]] ||
  fail "fresh migration must not write a site config"

rm -rf "$tmpd"
export PANGOLIN_ROOT="$old_pangolin_root"

echo "Task 8 tests passed"

# A failed fresh install has no backup to restore, so the service it enabled is
# disabled rather than left to restart-loop after reboot.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
for c in systemctl rc-update; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
old_path="$PATH"
old_pangolin_root="${PANGOLIN_ROOT:-}"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT=""
SITE_INSTALL_BACKUP_DIR=""
SITE_INSTALL_WAS_ACTIVE=0
_restore_install_paths systemd site || fail "fresh site failure should disable cleanly"
grep -q 'systemctl disable pangolin-site' "$tmpd/log" ||
  fail "failed fresh site install must disable the unit"
CLIENT_INSTALL_BACKUP_DIR=""
CLIENT_INSTALL_WAS_ACTIVE=0
_restore_install_paths openrc client || fail "fresh client failure should disable cleanly"
grep -q 'rc-update del pangolin-client default' "$tmpd/log" ||
  fail "failed fresh client install must leave the default runlevel"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
rm -rf "$tmpd"

# Task 10: legacy Newt files are backed up and removed only when called after a
# verified site install. Cleanup is a quiet no-op when nothing is present.
tmpd="$(mktemp -d)"
old_pangolin_root="$PANGOLIN_ROOT"
export PANGOLIN_ROOT="$tmpd/root"
mkdir -p "$tmpd/root/etc/newt" "$tmpd/root/usr/local/bin" "$tmpd/root/root" \
  "$tmpd/root/usr/bin"
newt_env="$tmpd/root/etc/newt/newt.env"
newt_bin="$tmpd/root/usr/local/bin/newt"
newt_marker="$tmpd/root/root/.newt"
printf 'NEWT_ID=nid\nNEWT_SECRET=nsec\nPANGOLIN_ENDPOINT=https://p.example\n' >"$newt_env"
chmod 600 "$newt_env"
printf 'binary\n' >"$newt_bin"
printf 'marker\n' >"$newt_marker"
if ! newt_out="$(cleanup_legacy_newt 2>&1)"; then
  fail "legacy Newt cleanup should succeed"
fi
case "$newt_out" in
*nsec*) fail "legacy Newt cleanup must not print the secret" ;;
esac
[[ ! -e "$newt_env" && ! -e "$newt_bin" && ! -e "$newt_marker" ]] ||
  fail "legacy Newt files should be removed"
[[ ! -d "$tmpd/root/etc/newt" ]] || fail "empty Newt directory should be removed"
newt_backup="$(find "$tmpd/root/var/lib/pangolin/backup" -name newt.env -print -quit)"
[[ -n "$newt_backup" ]] || fail "legacy Newt cleanup should back up the env file"
grep -q '^NEWT_SECRET=nsec$' "$newt_backup" || fail "Newt backup should keep the secret"
if ! newt_out="$(cleanup_legacy_newt 2>&1)"; then
  fail "repeated legacy Newt cleanup should succeed"
fi
[[ -z "$newt_out" ]] || fail "repeated legacy Newt cleanup should be quiet"
rm -rf "$tmpd"
export PANGOLIN_ROOT="$old_pangolin_root"

# Task 10: payload_main fails on a missing orchestrator flags file before it
# touches the service manager or the network.
tmpd="$(mktemp -d)"
if payload_main "$tmpd" >/dev/null 2>&1; then
  fail "payload_main without flags should fail"
fi
rm -rf "$tmpd"

echo "Task 10 tests passed"
