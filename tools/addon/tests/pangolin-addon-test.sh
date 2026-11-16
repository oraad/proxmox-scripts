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
grep -q "$tmpd/root/var/log/pangolin-site\*\.log" "$lr" || fail "logrotate site log glob"
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

# Multi-site Task 2: native + disableSsh key order, per-slug config paths, and
# interface-name defaults. Generation stays byte-compatible for legacy callers.
assert_eq \
  '{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangorga","nativeMain":true,"interfaceMain":"pangmorga","disableSsh":true}' \
  "$(site_config_static "https://p.example" "id" "secret" 1 1 pangorga pangmorga 1)"
assert_eq \
  '{"endpoint":"https://p.example","provisioningKey":"spk-1.secret","name":"pve-1","native":true,"interface":"pangorga","nativeMain":true,"interfaceMain":"pangmorga","disableSsh":true}' \
  "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 1 1 pangorga pangmorga 1)"

# disableSsh=0 appends no key; native off appends no native keys; the owner
# path and every legacy call shape stay byte-compatible.
assert_eq \
  '{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangorga","nativeMain":true,"interfaceMain":"pangmorga"}' \
  "$(site_config_static "https://p.example" "id" "secret" 1 1 pangorga pangmorga 0)"
assert_eq \
  '{"endpoint":"https://p.example","id":"id","secret":"secret","disableSsh":true}' \
  "$(site_config_static "https://p.example" "id" "secret" 0 0 pangolin pangolin 1)"
ssh_static="$(site_config_static "https://p.example" "id" "secret" 0 0 pangolin pangolin 1)"
if ! (python3 - "$ssh_static" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert list(d) == ["endpoint", "id", "secret", "disableSsh"], list(d)
assert d["disableSsh"] is True, d
PY
); then fail "disableSsh-only JSON shape: $ssh_static"; fi
prov_ssh="$(site_config_provisioning "https://p.example" "spk-1.key" "pve-1" 0 0 pangolin pangolin 1)"
if ! (python3 - "$prov_ssh" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert list(d) == ["endpoint", "provisioningKey", "name", "disableSsh"], list(d)
PY
); then fail "provisioning disableSsh shape: $prov_ssh"; fi
assert_eq "$static" "$(site_config_static "https://p.example" "id1" "sec1")"
assert_eq "$prov" "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
assert_eq "$both_static" \
  "$(site_config_static "https://p.example" "id1" "sec1" 1 1 "pangolin" "pangolin-main")"
assert_eq "$native_prov" \
  "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 0 1 "pangolin" "wg-main")"

# Slug config paths honor PANGOLIN_ROOT and the fixed layout.
root_tmp="$(mktemp -d)"
old_root="$PANGOLIN_ROOT"
export PANGOLIN_ROOT="$root_tmp/root"
assert_eq "$root_tmp/root/etc/pangolin/sites" "$(site_config_dir)"
assert_eq "$root_tmp/root/etc/pangolin/sites/org-a.json" "$(site_config_path org-a)"
assert_eq "$root_tmp/root/etc/pangolin/sites/default.json" "$(site_config_path default)"
[[ "$(site_config_path org-a)" != *$'\n'* ]] || fail "site_config_path must print one line"
export PANGOLIN_ROOT="$old_root"
rm -rf "$root_tmp"

# Interface defaults stay within Linux IFNAMSIZ (15 characters) for the
# maximum slug, and are valid interface names.
assert_eq pangorga "$(default_site_interface orga)"
assert_eq pangmorga "$(default_site_interface_main orga)"
assert_eq pangabcdefghij "$(default_site_interface abcdefghij)"
assert_eq pangmabcdefghij "$(default_site_interface_main abcdefghij)"
assert_eq "14" "$(printf '%s' "$(default_site_interface abcdefghij)" | wc -c)"
assert_eq "15" "$(printf '%s' "$(default_site_interface_main abcdefghij)" | wc -c)"

echo "Multi-site Task 2 tests passed"

# Multi-site Task 3: systemd template backend. The fake systemctl logs every
# call; FAKE_INACTIVE fails all is-active checks and FAKE_INACTIVE_UNIT fails
# only the named unit.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/etc/systemd/system"
cat >"$tmpd/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_LOG"
if [[ "$1" == "is-active" ]]; then
  unit="${*: -1}"
  [[ -z "${FAKE_INACTIVE_UNIT:-}" || "$unit" != "$FAKE_INACTIVE_UNIT" ]] || exit 3
  [[ "${FAKE_INACTIVE:-0}" != "1" ]] || exit 3
fi
exit 0
EOF
chmod 755 "$tmpd/bin/systemctl"

old_path="$PATH"
old_pangolin_root="$PANGOLIN_ROOT"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"
# Test-only wait overrides; the production policy stays 30x1s (probed below).
export PANGOLIN_SERVICE_ATTEMPTS=1
export PANGOLIN_SERVICE_DELAY=0

# (2) Slug-specific instance names.
assert_eq "pangolin-site@orga" "$(site_systemd_instance orga)"
assert_eq "pangolin-site@org-a" "$(site_systemd_instance org-a)"

# (1, 3) Template exact lines, literal %i config path, 0644 unit, 0700 sites
# directory, and a daemon-reload.
write_site_systemd_template || fail "template write should succeed"
unit_file="$tmpd/root/etc/systemd/system/pangolin-site@.service"
[[ -f "$unit_file" ]] || fail "template unit should exist"
[[ "$(stat -c '%a' "$unit_file")" == "644" ]] || fail "template unit mode"
[[ "$(stat -c '%a' "$tmpd/root/etc/pangolin/sites")" == "700" ]] || fail "sites dir mode"
grep -q "systemctl daemon-reload" "$FAKE_LOG" || fail "template write must reload systemd"
expected_unit="[Unit]
Description=Pangolin Site (CLI)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=CONFIG_FILE=/etc/pangolin/sites/%i.json
ExecStart=$PANGOLIN_BIN up site
Restart=always
RestartSec=2
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target"
assert_eq "$expected_unit" "$(cat "$unit_file")"
# The in-unit config path is the production absolute path, never the test root.
grep -qx 'Environment=CONFIG_FILE=/etc/pangolin/sites/%i.json' "$unit_file" ||
  fail "unit must keep the literal production config path"

cfg="$(site_config_path orga)"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"

# (4) A fresh instance is enabled with --now and not restarted.
: >"$FAKE_LOG"
start_site_systemd_slug orga 0 || fail "fresh instance should start"
grep -q "systemctl enable --now pangolin-site@orga" "$FAKE_LOG" || fail "instance enable"
if grep -q "systemctl restart pangolin-site@orga" "$FAKE_LOG"; then
  fail "fresh instance must not restart"
fi

# (5, 6) An active instance enables, restarts, then waits on the instance name.
: >"$FAKE_LOG"
start_site_systemd_slug orga 1 || fail "active instance should start"
grep -q "systemctl restart pangolin-site@orga" "$FAKE_LOG" || fail "active instance should restart"
grep -q "systemctl is-active --quiet pangolin-site@orga" "$FAKE_LOG" ||
  fail "the wait must use the templated instance name"
enable_line="$(grep -n "systemctl enable --now pangolin-site@orga" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
restart_line="$(grep -n "systemctl restart pangolin-site@orga" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
active_line="$(grep -n "systemctl is-active --quiet pangolin-site@orga" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ "$enable_line" -lt "$restart_line" ]] || fail "enable must precede the restart"
[[ "$restart_line" -lt "$active_line" ]] || fail "restart must precede the active wait"

# (7) The provisioning wait uses the per-slug config.
prov_cfg="$(site_config_path provorg)"
write_private_file "$prov_cfg" "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
if verify_site_systemd_slug provorg "$prov_cfg"; then
  fail "verify must wait on the per-slug provisioning config"
fi
verify_site_systemd_slug orga "$cfg" || fail "verify with the slug credentials should pass"

# The production wait policy stays 30x1s when the test overrides are unset.
policy="$(
  unset PANGOLIN_SERVICE_ATTEMPTS PANGOLIN_SERVICE_DELAY
  wait_service_active() {
    printf '%s %s' "$3" "$4"
    return 0
  }
  verify_site_systemd_slug orga "$cfg"
)" || fail "policy probe should pass"
assert_eq "30 1" "$policy"

# site_instance_was_active reports the instance state from systemctl.
site_instance_was_active orga || fail "instance should read as active"
export FAKE_INACTIVE_UNIT='pangolin-site@orga'
if site_instance_was_active orga; then fail "inactive instance should read false"; fi
unset FAKE_INACTIVE_UNIT

# stop_site_systemd_slug stops the templated instance.
: >"$FAKE_LOG"
stop_site_systemd_slug orga || fail "stop should succeed"
grep -q "systemctl stop pangolin-site@orga" "$FAKE_LOG" || fail "instance stop call"

# (8) Disable stops an active instance, disables it, and removes the enabled
# instance symlink under multi-user.target.wants.
mkdir -p "$tmpd/root/etc/systemd/system/multi-user.target.wants"
wants_link="$tmpd/root/etc/systemd/system/multi-user.target.wants/pangolin-site@orga.service"
ln -sf "$unit_file" "$wants_link"
: >"$FAKE_LOG"
disable_site_systemd_slug orga || fail "disable should succeed"
grep -q "systemctl stop pangolin-site@orga" "$FAKE_LOG" || fail "disable must stop the instance"
grep -q "systemctl disable pangolin-site@orga" "$FAKE_LOG" || fail "instance disable call"
[[ ! -L "$wants_link" ]] || fail "disable must remove the enabled instance symlink"

# Remove disables the instance and keeps the per-slug config for diagnostics.
ln -sf "$unit_file" "$wants_link"
: >"$FAKE_LOG"
remove_site_systemd_slug orga || fail "remove should succeed"
grep -q "systemctl disable pangolin-site@orga" "$FAKE_LOG" || fail "instance remove disables"
[[ ! -L "$wants_link" ]] || fail "remove must clear the enabled instance symlink"
[[ -f "$cfg" ]] || fail "remove must keep the per-slug config"
[[ -f "$unit_file" ]] || fail "remove must keep the shared template"

# (9) A failure after enable reports no success and leaves the template for
# rollback. The install helper never touches the legacy unit, even while a
# legacy install is present and running.
mkdir -p "$tmpd/root/etc/systemd/system/multi-user.target.wants"
legacy_unit_file="$tmpd/root/etc/systemd/system/pangolin-site.service"
legacy_link="$tmpd/root/etc/systemd/system/multi-user.target.wants/pangolin-site.service"
printf '[Unit]\n' >"$legacy_unit_file"
ln -sf "$legacy_unit_file" "$legacy_link"
: >"$FAKE_LOG"
inst_rc=0
inst_out="$(
  wait_service_active() { return 1; }
  install_site_systemd_slug orga "$cfg" 2>/dev/null
)" || inst_rc=$?
[[ "$inst_rc" -ne 0 ]] || fail "an instance that never activates must fail"
[[ -z "$inst_out" ]] || fail "a failed instance install must not report success"
[[ -f "$unit_file" ]] || fail "a failed install must leave the template for rollback"
if grep -qE "systemctl (stop|disable|restart) pangolin-site$" "$FAKE_LOG"; then
  fail "a failed instance install must not touch the legacy unit"
fi
[[ -f "$legacy_unit_file" ]] || fail "a failed install must leave the legacy unit file"
[[ -L "$legacy_link" ]] || fail "a failed install must leave the legacy wants symlink"

# The success path writes the template, enables the instance, restarts a
# previously-active one, and verifies. Legacy retirement is a separate,
# caller-ordered step (Task 5 stops the legacy service before this starts and
# calls retire_legacy_single_site_systemd after verification), so the install
# helper leaves the legacy unit, its symlink, and the files on disk alone.
: >"$FAKE_LOG"
install_site_systemd_slug orga "$cfg" 1 || fail "slug install should succeed"
grep -q "systemctl daemon-reload" "$FAKE_LOG" || fail "slug install must write the template"
grep -q "systemctl enable --now pangolin-site@orga" "$FAKE_LOG" || fail "slug install must enable the instance"
grep -q "systemctl restart pangolin-site@orga" "$FAKE_LOG" || fail "active slug must restart its instance"
grep -q "systemctl is-active --quiet pangolin-site@orga" "$FAKE_LOG" || fail "slug install must verify the instance"
if grep -qE "systemctl (stop|disable|restart) pangolin-site$" "$FAKE_LOG"; then
  fail "the instance install must never touch the legacy unit"
fi
[[ -f "$legacy_unit_file" ]] || fail "the instance install must not remove the legacy unit file"
[[ -L "$legacy_link" ]] || fail "the instance install must not remove the legacy wants symlink"

# retire_legacy_single_site_systemd stops an active legacy service, disables
# it, removes the unit file and its wants symlink, and reloads systemd. The
# per-slug config, the legacy site.json, the template, and install backups
# stay in place for the caller.
write_private_file "$tmpd/root/etc/pangolin/site.json" \
  "$(site_config_static "https://p.example" id1 sec1)"
LEGACY_SITE_BACKUP_DIR="$tmpd/pretend-backup"
: >"$FAKE_LOG"
retire_legacy_single_site_systemd || fail "retire should succeed"
grep -q "systemctl stop pangolin-site$" "$FAKE_LOG" || fail "retire must stop an active legacy unit"
grep -q "systemctl disable pangolin-site$" "$FAKE_LOG" || fail "retire must disable the legacy unit"
grep -q "systemctl daemon-reload" "$FAKE_LOG" || fail "retire must reload systemd"
[[ ! -e "$legacy_unit_file" ]] || fail "retire must remove the legacy unit file"
[[ ! -e "$legacy_link" ]] || fail "retire must remove the legacy wants symlink"
[[ -f "$cfg" ]] || fail "retire must keep the per-slug config"
[[ -f "$tmpd/root/etc/pangolin/site.json" ]] || fail "retire must keep the legacy site config"
[[ -f "$unit_file" ]] || fail "retire must keep the shared template"
assert_eq "$tmpd/pretend-backup" "$LEGACY_SITE_BACKUP_DIR"

# On a host without a legacy install retire is a quiet no-op: no service
# manager call beyond the state probe, and no files touched.
rm -f "$legacy_link"
: >"$FAKE_LOG"
noise="$(FAKE_INACTIVE_UNIT=pangolin-site retire_legacy_single_site_systemd 2>&1)" ||
  fail "retire on a fresh host should succeed"
[[ -z "$noise" ]] || fail "retire on a fresh host printed: $noise"
if grep -qE "systemctl (stop|disable|daemon-reload) pangolin-site$|systemctl daemon-reload" "$FAKE_LOG"; then
  fail "retire must not act without a legacy unit"
fi

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
unset PANGOLIN_SERVICE_ATTEMPTS PANGOLIN_SERVICE_DELAY

# (10) Legacy single-instance helpers keep the old behavior: with a test root
# and the fake off PATH, install_site_systemd still calls the CLI and waits on
# the plain unit name.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
for c in systemctl pangolin; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/bin/pangolin"
cfg="$tmpd/site.json"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_systemd "$cfg" 1 || fail "legacy install should still succeed"
grep -q "pangolin service install site --config-file $cfg" "$FAKE_LOG" || fail "legacy CLI install call"
grep -q "systemctl restart pangolin-site$" "$FAKE_LOG" || fail "legacy restart call"
grep -q "systemctl is-active --quiet pangolin-site$" "$FAKE_LOG" || fail "legacy wait on the plain unit"
if grep -q "pangolin-site@" "$FAKE_LOG"; then
  fail "the legacy install path must not use template instances"
fi
if ls "$tmpd/root/etc/systemd/system" >/dev/null 2>&1; then
  fail "the legacy install must not write template units"
fi
rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi

echo "Multi-site Task 3 tests passed"

# Multi-site Task 4: per-slug OpenRC backend. The fakes log every rc-update and
# rc-service call; rc-service "status" fails for FAKE_INACTIVE_UNIT (or all when
# FAKE_INACTIVE=1). The per-slug wrapper execs the fake pangolin, which records
# argv and the exported CONFIG_FILE so the production path is verified end-to-end.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/etc/init.d" "$tmpd/root/usr/local/bin" \
  "$tmpd/root/etc/pangolin" "$tmpd/root/etc/logrotate.d" "$tmpd/root/var/log" \
  "$tmpd/root/etc/runlevels/default"
# rc-update models the default-runlevel symlink so that `del` fails (exit 1) when
# the service was never added, mirroring real OpenRC and exposing idempotence bugs.
cat >"$tmpd/bin/rc-update" <<'EOF'
#!/usr/bin/env bash
echo "rc-update $*" >>"$FAKE_LOG"
case "$1" in
add) ln -sf "$PANGOLIN_ROOT/etc/init.d/$2" "$PANGOLIN_ROOT/etc/runlevels/default/$2" ;;
del)
  entry="$PANGOLIN_ROOT/etc/runlevels/default/$2"
  if [[ -e "$entry" || -L "$entry" ]]; then rm -f "$entry"; else exit 1; fi
  ;;
esac
exit 0
EOF
chmod 755 "$tmpd/bin/rc-update"
for c in supervise-daemon logrotate; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
cat >"$tmpd/bin/rc-service" <<'EOF'
#!/usr/bin/env bash
echo "rc-service $*" >>"$FAKE_LOG"
if [[ "$2" == "status" ]]; then
  [[ -z "${FAKE_INACTIVE_UNIT:-}" || "$1" != "$FAKE_INACTIVE_UNIT" ]] || exit 3
  [[ "${FAKE_INACTIVE:-0}" != "1" ]] || exit 3
fi
exit 0
EOF
cat >"$tmpd/bin/pangolin" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >>"$FAKE_LOG"
printf 'CONFIG_FILE=%s\n' "${CONFIG_FILE:-}" >>"$FAKE_LOG"
EOF
chmod 755 "$tmpd/bin/rc-service" "$tmpd/bin/pangolin"

old_path="$PATH"
old_pangolin_root="$PANGOLIN_ROOT"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/bin/pangolin"
# Test-only wait overrides; the production policy stays 30x1s.
export PANGOLIN_SERVICE_ATTEMPTS=1
export PANGOLIN_SERVICE_DELAY=0

# (2) Slug-specific instance names.
assert_eq "pangolin-site-orga" "$(site_openrc_instance orga)"
assert_eq "pangolin-site-org-a" "$(site_openrc_instance org-a)"

# (1, 3) Per-slug wrapper and unit. The wrapper's CONFIG_FILE is the production
# path, never the test root; the unit is named and located per slug.
cfg="$(site_config_path org-a)"
[[ "$cfg" == *"/etc/pangolin/sites/org-a.json" ]] || fail "config path layout"
write_private_file "$cfg" "$(site_config_static "https://p.example" id1 sec1)"
write_site_openrc_slug org-a "$cfg" || fail "per-slug write should succeed"
slug_unit="$tmpd/root/etc/init.d/pangolin-site-org-a"
slug_wrapper="$tmpd/root/usr/local/bin/pangolin-site-org-a-start"
[[ -f "$slug_unit" ]] || fail "per-slug unit should exist at the slug path"
[[ -f "$slug_wrapper" ]] || fail "per-slug wrapper should exist at the slug path"
grep -qx 'name="pangolin-site-org-a"' "$slug_unit" || fail "unit name is the slug instance"
grep -q "CONFIG_FILE='/etc/pangolin/sites/org-a.json'" "$slug_wrapper" ||
  fail "wrapper must use the production config path"
if grep -q "$tmpd/root" "$slug_wrapper"; then
  fail "wrapper must not bake in the test root"
fi
# No credential material may be written into the wrapper: it only holds the
# config path and the exec line.
if grep -qE 'sec1|id1|https://p\.example' "$slug_wrapper"; then
  fail "per-slug wrapper must not contain credentials"
fi

# A config path outside PANGOLIN_ROOT is refused before any file is written:
# stripping an unrelated prefix would bake a wrong CONFIG_FILE into the wrapper.
outside="$tmpd/elsewhere/etc/pangolin/sites/org-a.json"
if err="$(write_site_openrc_slug orgd "$outside" 2>&1 >/dev/null)"; then
  fail "write must refuse a config path outside PANGOLIN_ROOT"
fi
case "$err" in
*"not under"*) ;;
*) fail "expected a prefix error, got: $err" ;;
esac
[[ ! -e "$tmpd/root/etc/init.d/pangolin-site-orgd" ]] ||
  fail "a refused write must not create a unit"
[[ ! -e "$tmpd/root/usr/local/bin/pangolin-site-orgd-start" ]] ||
  fail "a refused write must not create a wrapper"

# (2, 4) Modes and supervise-daemon restart settings.
[[ "$(stat -c '%a' "$slug_wrapper")" == "700" ]] || fail "per-slug wrapper mode"
[[ "$(stat -c '%a' "$slug_unit")" == "755" ]] || fail "per-slug unit mode"
grep -q 'supervisor=supervise-daemon' "$slug_unit" || fail "per-slug supervisor"
grep -q 'respawn_delay=2' "$slug_unit" || fail "per-slug respawn delay"
grep -q 'respawn_max=0' "$slug_unit" || fail "per-slug respawn max"
grep -q 'command_user=root' "$slug_unit" || fail "per-slug command user"
grep -q "command=\"$slug_wrapper\"" "$slug_unit" || fail "per-slug unit command"
grep -q "output_log=\"$tmpd/root/var/log/pangolin-site-org-a.log\"" "$slug_unit" ||
  fail "per-slug log path"

# (7) The active wait and provisioning check use the instance name. verify passes
# on the slug's credential config and fails on a provisioning-key config.
: >"$FAKE_LOG"
verify_site_openrc_slug org-a "$cfg" || fail "verify should pass with credentials"
grep -q 'rc-service pangolin-site-org-a status' "$FAKE_LOG" ||
  fail "the wait must use the slug instance name"
prov_cfg="$(site_config_path provorg)"
write_private_file "$prov_cfg" "$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1")"
if verify_site_openrc_slug provorg "$prov_cfg"; then
  fail "verify must wait on the per-slug provisioning config"
fi

# site_instance_was_active_openrc reports the instance state from rc-service.
site_instance_was_active_openrc org-a || fail "instance should read as active"
export FAKE_INACTIVE_UNIT='pangolin-site-org-a'
if site_instance_was_active_openrc org-a; then fail "inactive instance should read false"; fi
unset FAKE_INACTIVE_UNIT

# (5, 6) Fresh start enables and starts without restarting; an active start
# restarts after start and before the active wait.
: >"$FAKE_LOG"
start_site_openrc_slug org-a 0 || fail "fresh instance should start"
grep -q 'rc-update add pangolin-site-org-a default' "$FAKE_LOG" || fail "instance enable"
grep -q 'rc-service pangolin-site-org-a start' "$FAKE_LOG" || fail "instance start"
if grep -q 'rc-service pangolin-site-org-a restart' "$FAKE_LOG"; then
  fail "fresh instance must not restart"
fi
: >"$FAKE_LOG"
start_site_openrc_slug org-a 1 || fail "active instance should start"
grep -q 'rc-service pangolin-site-org-a restart' "$FAKE_LOG" || fail "active instance should restart"
start_line="$(grep -n 'rc-service pangolin-site-org-a start' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
restart_line="$(grep -n 'rc-service pangolin-site-org-a restart' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
status_line="$(grep -n 'rc-service pangolin-site-org-a status' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ "$start_line" -lt "$restart_line" ]] || fail "start must precede the restart"
[[ "$restart_line" -lt "$status_line" ]] || fail "restart must precede the active wait"

# stop_site_openrc_slug stops the slug instance.
: >"$FAKE_LOG"
stop_site_openrc_slug org-a || fail "stop should succeed"
grep -q 'rc-service pangolin-site-org-a stop' "$FAKE_LOG" || fail "instance stop call"

# (8) Disable stops an active instance and removes it from the default runlevel.
: >"$FAKE_LOG"
disable_site_openrc_slug org-a || fail "disable should succeed"
grep -q 'rc-service pangolin-site-org-a stop' "$FAKE_LOG" || fail "disable must stop the instance"
grep -q 'rc-update del pangolin-site-org-a default' "$FAKE_LOG" || fail "instance disable call"

# (8b) Idempotence: an init script present but with no default-runlevel entry (a
# failed fresh install whose generic cleanup already removed the link) must not
# call rc-update del, which OpenRC fails for an unadded service, and must not
# return an error.
printf '#!/sbin/openrc-run\n' >"$tmpd/root/etc/init.d/pangolin-site-orgidem"
: >"$FAKE_LOG"
FAKE_INACTIVE_UNIT=pangolin-site-orgidem \
  disable_site_openrc_slug orgidem || fail "disable must be idempotent without a runlevel entry"
if grep -q 'rc-update del pangolin-site-orgidem default' "$FAKE_LOG"; then
  fail "disable must skip rc-update del when not in the runlevel"
fi

# (10) log rotation globs the per-slug site logs plus the unchanged client log.
lr="$tmpd/root/etc/logrotate.d/pangolin"
[[ -f "$lr" ]] || fail "logrotate config should be written"
grep -q "$tmpd/root/var/log/pangolin-site\*\.log" "$lr" || fail "logrotate site glob"
grep -q "$tmpd/root/var/log/pangolin-client.log" "$lr" || fail "logrotate client log path"

# The wrapper runs against the CLI with the production config exported, and the
# exec line carries no credentials.
"$slug_wrapper" || fail "per-slug wrapper should run"
grep -q "^CONFIG_FILE=/etc/pangolin/sites/org-a.json$" "$FAKE_LOG" ||
  fail "wrapper must export the production CONFIG_FILE"
grep -q '^argv=up site$' "$FAKE_LOG" || fail "wrapper argv"

# (11) install_site_openrc_slug never touches the legacy single instance, on
# either the success or the failure path, even with a legacy install present and
# running. Legacy retirement is a separate caller-ordered step (Task 5).
legacy_init="$tmpd/root/etc/init.d/pangolin-site"
legacy_wrapper="$tmpd/root/usr/local/bin/pangolin-site-start"
printf '#!/sbin/openrc-run\n' >"$legacy_init"
printf '#!/bin/sh\nexec old-site-start\n' >"$legacy_wrapper"
write_private_file "$tmpd/root/etc/pangolin/site.json" \
  "$(site_config_static "https://p.example" id1 sec1)"

: >"$FAKE_LOG"
install_site_openrc_slug org-a "$cfg" 1 || fail "per-slug install should succeed"
if grep -qE 'rc-service pangolin-site (stop|start|restart|status)' "$FAKE_LOG" ||
  grep -qE 'rc-update (add|del) pangolin-site default' "$FAKE_LOG"; then
  fail "the per-slug install must never act on the legacy service"
fi
[[ -f "$legacy_init" ]] || fail "per-slug install must leave the legacy init file"
[[ -f "$legacy_wrapper" ]] || fail "per-slug install must leave the legacy wrapper"

# The failure path: org-b has its own config, and a stubbed wait makes the
# install fail without success output or any legacy action. Its wrapper must
# point at sites/org-b.json, not another slug's config, and carry no secret.
cfg_b="$(site_config_path org-b)"
write_private_file "$cfg_b" "$(site_config_static "https://p.example" idb secb)"
inst_rc=0
inst_out="$(
  wait_service_active() { return 1; }
  install_site_openrc_slug org-b "$cfg_b" 2>/dev/null
)" || inst_rc=$?
[[ "$inst_rc" -ne 0 ]] || fail "an instance that never activates must fail"
[[ -z "$inst_out" ]] || fail "a failed instance install must not report success"
[[ -f "$legacy_init" ]] || fail "a failed install must leave the legacy init file"
[[ -f "$legacy_wrapper" ]] || fail "a failed install must leave the legacy wrapper"
orgb_wrapper="$tmpd/root/usr/local/bin/pangolin-site-org-b-start"
grep -q "CONFIG_FILE='/etc/pangolin/sites/org-b.json'" "$orgb_wrapper" ||
  fail "the org-b wrapper must point at the org-b config"
if grep -qE 'secb|idb|https://p\.example' "$orgb_wrapper"; then
  fail "the org-b wrapper must not contain credentials"
fi

# (12) retire_legacy_single_site_openrc stops the legacy service, removes it from
# the default runlevel, and deletes its init, wrapper, and runlevel symlink.
# Per-slug units, configs, and the legacy site.json all survive for the caller.
ln -sf "$legacy_init" "$tmpd/root/etc/runlevels/default/pangolin-site"
: >"$FAKE_LOG"
retire_legacy_single_site_openrc || fail "retire should succeed"
grep -q 'rc-service pangolin-site stop' "$FAKE_LOG" || fail "retire must stop an active legacy service"
grep -q 'rc-update del pangolin-site default' "$FAKE_LOG" || fail "retire must disable the legacy service"
[[ ! -e "$legacy_init" ]] || fail "retire must remove the legacy init file"
[[ ! -e "$legacy_wrapper" ]] || fail "retire must remove the legacy wrapper"
[[ ! -e "$tmpd/root/etc/runlevels/default/pangolin-site" ]] ||
  fail "retire must remove the legacy runlevel symlink"
[[ -f "$slug_unit" ]] || fail "retire must keep the per-slug unit"
[[ -f "$slug_wrapper" ]] || fail "retire must keep the per-slug wrapper"
[[ -f "$cfg" ]] || fail "retire must keep the per-slug config"
[[ -f "$cfg_b" ]] || fail "retire must keep the other per-slug config"
[[ -f "$tmpd/root/etc/pangolin/site.json" ]] || fail "retire must keep the legacy site config"

# On a host with no legacy unit retire is a quiet no-op: the inactive probe aside,
# it issues no stop or rc-update del and touches no files.
: >"$FAKE_LOG"
noise="$(FAKE_INACTIVE_UNIT=pangolin-site retire_legacy_single_site_openrc 2>&1)" ||
  fail "retire on a fresh host should succeed"
[[ -z "$noise" ]] || fail "retire on a fresh host printed: $noise"
if grep -qE 'rc-service pangolin-site (stop|start|restart)|rc-update del pangolin-site default' "$FAKE_LOG"; then
  fail "retire must not act without a legacy unit"
fi

# An orphaned runlevel symlink with no init script or wrapper (the systemd
# sibling likewise removes its wants symlink) is still retired: the entry is in
# the existence check and the removal set, so rc-update del runs and the link is
# cleared even though the service is not running. The prior retire removed the
# init and wrapper, so only the runlevel link is created here.
: >"$FAKE_LOG"
ln -sf "$legacy_init" "$tmpd/root/etc/runlevels/default/pangolin-site"
noise="$(FAKE_INACTIVE_UNIT=pangolin-site retire_legacy_single_site_openrc 2>&1)" ||
  fail "retire of an orphan runlevel link should succeed"
[[ -z "$noise" ]] || fail "retire of an orphan link printed: $noise"
grep -q 'rc-update del pangolin-site default' "$FAKE_LOG" ||
  fail "retire must clear the runlevel entry for an orphan link"
if grep -q 'rc-service pangolin-site stop' "$FAKE_LOG"; then
  fail "retire must not stop an inactive legacy service"
fi
[[ ! -e "$tmpd/root/etc/runlevels/default/pangolin-site" ]] ||
  fail "retire must remove the orphan runlevel symlink"

# A missing supervise-daemon means the unit cannot restart, so the write refuses
# before creating any file.
mkdir -p "$tmpd/no-supervise"
for c in rc-update rc-service logrotate pangolin; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmpd/no-supervise/$c"
  chmod 755 "$tmpd/no-supervise/$c"
done
if supervise_err="$(PATH="$tmpd/no-supervise" write_site_openrc_slug orgc "$cfg" 2>&1 >/dev/null)"; then
  fail "missing supervise-daemon should fail"
fi
case "$supervise_err" in
*supervise-daemon*) ;;
*) fail "missing supervise-daemon should name it, got: $supervise_err" ;;
esac
[[ ! -e "$tmpd/root/etc/init.d/pangolin-site-orgc" ]] ||
  fail "a refused write must not create a unit"

# (9) The production wait policy stays 30x1s when the test overrides are unset.
policy="$(
  unset PANGOLIN_SERVICE_ATTEMPTS PANGOLIN_SERVICE_DELAY
  wait_service_active() {
    printf '%s %s' "$3" "$4"
    return 0
  }
  wait_for_provisioning() { return 0; }
  verify_site_openrc_slug org-a "$cfg"
)" || fail "policy probe should pass"
assert_eq "30 1" "$policy"

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
unset PANGOLIN_SERVICE_ATTEMPTS PANGOLIN_SERVICE_DELAY

# (13) The legacy single-site OpenRC install keeps its behavior: with a test root
# and the fake PATH it still writes the plain wrapper and unit and enables the
# plain service name, and its wrapper embeds the passed config path unchanged.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin" "$tmpd/root/etc/init.d" "$tmpd/root/usr/local/bin" \
  "$tmpd/root/etc/pangolin" "$tmpd/root/var/log"
for c in rc-update rc-service supervise-daemon logrotate; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
  chmod 755 "$tmpd/bin/$c"
done
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"
single_cfg="$tmpd/root/etc/pangolin/site.json"
write_private_file "$single_cfg" "$(site_config_static "https://p.example" id1 sec1)"
install_site_openrc "$single_cfg" 1 || fail "legacy site install should succeed"
[[ -f "$tmpd/root/etc/init.d/pangolin-site" ]] || fail "legacy unit at plain path"
[[ -f "$tmpd/root/usr/local/bin/pangolin-site-start" ]] || fail "legacy wrapper at plain path"
grep -q "CONFIG_FILE=$single_cfg" "$tmpd/root/usr/local/bin/pangolin-site-start" ||
  fail "legacy wrapper embeds the passed config path"
grep -q 'rc-update add pangolin-site default' "$FAKE_LOG" || fail "legacy enable"
grep -q 'rc-service pangolin-site restart' "$FAKE_LOG" || fail "legacy restart"
if grep -q "pangolin-site-" "$FAKE_LOG"; then
  fail "the legacy single-site path must not use slug services"
fi

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi

echo "Multi-site Task 4 tests passed"

# Multi-site Task 5: one-way legacy conversion and instance cleanup. The fakes
# log every service-manager call so the conversion ordering is asserted, not
# assumed. FAKE_INACTIVE_UNIT fails is-active/status for one named unit only.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
cat >"$tmpd/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_LOG"
if [[ "$1" == "is-active" ]]; then
  unit="${*: -1}"
  [[ -z "${FAKE_INACTIVE_UNIT:-}" || "$unit" != "$FAKE_INACTIVE_UNIT" ]] || exit 3
  [[ "${FAKE_INACTIVE:-0}" != "1" ]] || exit 3
fi
exit 0
EOF
cat >"$tmpd/bin/rc-service" <<'EOF'
#!/usr/bin/env bash
echo "rc-service $*" >>"$FAKE_LOG"
if [[ "$2" == "status" ]]; then
  [[ -z "${FAKE_INACTIVE_UNIT:-}" || "$1" != "$FAKE_INACTIVE_UNIT" ]] || exit 3
  [[ "${FAKE_INACTIVE:-0}" != "1" ]] || exit 3
fi
exit 0
EOF
cat >"$tmpd/bin/rc-update" <<'EOF'
#!/usr/bin/env bash
echo "rc-update $*" >>"$FAKE_LOG"
case "$1" in
add) ln -sf "$PANGOLIN_ROOT/etc/init.d/$2" "$PANGOLIN_ROOT/etc/runlevels/default/$2" ;;
del)
  entry="$PANGOLIN_ROOT/etc/runlevels/default/$2"
  if [[ -e "$entry" || -L "$entry" ]]; then rm -f "$entry"; else exit 1; fi
  ;;
esac
exit 0
EOF
for c in supervise-daemon logrotate; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$c" >"$tmpd/bin/$c"
done
printf '#!/usr/bin/env bash\necho "pangolin $*" >>"$FAKE_LOG"\nexit 0\n' >"$tmpd/bin/pangolin"
chmod 755 "$tmpd"/bin/*

old_path="$PATH"
old_pangolin_root="$PANGOLIN_ROOT"
old_pangolin_bin="$PANGOLIN_BIN"
old_fake_log="${FAKE_LOG:-}"
old_fake_inactive_unit="${FAKE_INACTIVE_UNIT:-}"
old_newt_id="$LEGACY_NEWT_ID"
old_newt_secret="$LEGACY_NEWT_SECRET"
old_newt_endpoint="$LEGACY_ENDPOINT"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
export PANGOLIN_ROOT="$tmpd/root"
export PANGOLIN_BIN="$tmpd/root/usr/local/bin/pangolin"
export PANGOLIN_SERVICE_ATTEMPTS=1
export PANGOLIN_SERVICE_DELAY=0

t5_root="$tmpd/root"
t5_reset_root() {
  rm -rf "$t5_root"
  mkdir -p "$t5_root/etc/systemd/system/multi-user.target.wants" \
    "$t5_root/etc/init.d" "$t5_root/etc/runlevels/default" "$t5_root/usr/local/bin" \
    "$t5_root/etc/pangolin" "$t5_root/etc/logrotate.d" "$t5_root/var/log" \
    "$t5_root/var/lib/pangolin" "$t5_root/usr/bin"
}
t5_legacy_systemd() {
  printf 'UNIT-ORIGINAL\n' >"$t5_root/etc/systemd/system/pangolin-site.service"
  ln -sf ../pangolin-site.service \
    "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service"
}
t5_legacy_openrc() {
  printf '#!/sbin/openrc-run\nlegacy\n' >"$t5_root/etc/init.d/pangolin-site"
  printf '#!/bin/sh\n. /etc/pangolin/pangolin-site.env\nexec pangolin up site\n' \
    >"$t5_root/usr/local/bin/pangolin-site-start"
  ln -sf "$t5_root/etc/init.d/pangolin-site" "$t5_root/etc/runlevels/default/pangolin-site"
}
t5_legacy_env() {
  printf 'SITE_ID=oldid\nSITE_SECRET=oldsecret\nPANGOLIN_ENDPOINT=https://p.example\n' \
    >"$t5_root/etc/pangolin/pangolin-site.env"
  chmod 600 "$t5_root/etc/pangolin/pangolin-site.env"
}
t5_updater() {
  printf '#!/bin/sh\nexec old-site-updater\n' >"$t5_root/usr/bin/update-pangolin-site"
  chmod 755 "$t5_root/usr/bin/update-pangolin-site"
}
t5_marker() { printf '%s\n' "$1" >"$t5_root/var/lib/pangolin/site-layout"; }
t5_default_cfg="$(site_config_path default)"
t5_cred="$(site_config_static "https://p.example" id1 s3cr3t-static)"

printf 'MULTI_SITE=1\n' >"$tmpd/flags-on"
printf 'MULTI_SITE=0\n' >"$tmpd/flags-off"

# (1) State detection: single, template, mixed. The detector is pure file
# inspection: the fake log must stay empty across every call.
t5_reset_root
assert_eq single "$(site_conversion_state)"
: >"$FAKE_LOG"

t5_legacy_systemd
assert_eq single "$(site_conversion_state)"
printf 'SITE_ID=old\n' >"$t5_root/etc/pangolin/pangolin-site.env"
assert_eq single "$(site_conversion_state)"
rm -f "$t5_root/etc/pangolin/pangolin-site.env"
printf '[Unit]\n' >"$t5_root/etc/systemd/system/pangolin-site@.service"
assert_eq mixed "$(site_conversion_state)"
rm -f "$t5_root/etc/systemd/system/pangolin-site.service"
rm -f "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service"
assert_eq template "$(site_conversion_state)"
rm -f "$t5_root/etc/systemd/system/pangolin-site@.service"
assert_eq single "$(site_conversion_state)"

# OpenRC per-slug units mark the template layout; the legacy init or its
# runlevel entry alongside a slug unit is mixed.
printf '#!/sbin/openrc-run\n' >"$t5_root/etc/init.d/pangolin-site-orga"
assert_eq template "$(site_conversion_state)"
printf '#!/sbin/openrc-run\nlegacy\n' >"$t5_root/etc/init.d/pangolin-site"
assert_eq mixed "$(site_conversion_state)"
rm -f "$t5_root/etc/init.d/pangolin-site" "$t5_root/etc/init.d/pangolin-site-orga"
assert_eq single "$(site_conversion_state)"
ln -sf /nonexistent "$t5_root/etc/runlevels/default/pangolin-site"
assert_eq single "$(site_conversion_state)"
t5_marker template
assert_eq mixed "$(site_conversion_state)"
rm -f "$t5_root/etc/runlevels/default/pangolin-site"
assert_eq template "$(site_conversion_state)"
t5_marker single
assert_eq single "$(site_conversion_state)"
rm -f "$t5_root/var/lib/pangolin/site-layout"
# A legacy wants symlink alone still counts as a legacy service artifact.
ln -sf ../pangolin-site.service \
  "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service"
printf '[Unit]\n' >"$t5_root/etc/systemd/system/pangolin-site@.service"
assert_eq mixed "$(site_conversion_state)"
rm -f "$t5_root/etc/systemd/system/pangolin-site@.service" \
  "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service"
[[ ! -s "$FAKE_LOG" ]] || fail "detection must not call the service manager"

# (1b) multi_site_requested: flags file, MULTI_SITE env, var_multi_sites.
multi_site_requested "$tmpd/flags-on" || fail "MULTI_SITE=1 flags file should request conversion"
if multi_site_requested "$tmpd/flags-off"; then fail "MULTI_SITE=0 must not request conversion"; fi
if multi_site_requested "$tmpd/does-not-exist"; then fail "missing flags file must not request"; fi
(export MULTI_SITE=1; multi_site_requested) || fail "MULTI_SITE env should request"
(export var_multi_sites=1; multi_site_requested) || fail "var_multi_sites env should request"
printf 'SITE=1\n' >"$tmpd/flags-none"
(export MULTI_SITE=1; multi_site_requested "$tmpd/flags-none") ||
  fail "a flags file without the key must fall back to the env"
if (export MULTI_SITE=1; multi_site_requested "$tmpd/flags-off"); then
  fail "an explicit MULTI_SITE=0 in flags must beat the env"
fi
if (unset MULTI_SITE var_multi_sites; multi_site_requested "$tmpd/flags-off"); then
  fail "no flags and no env must not request"
fi

# (1c) Marker writer: 0644, validated value.
write_site_conversion_marker template || fail "marker write should succeed"
assert_eq "$(cat "$t5_root/var/lib/pangolin/site-layout")" "template"
assert_eq "644" "$(stat -c '%a' "$t5_root/var/lib/pangolin/site-layout")"
if write_site_conversion_marker bogus >/dev/null 2>&1; then fail "bad marker value should fail"; fi
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
write_site_conversion_marker single || fail "single marker write should succeed"
assert_eq "single" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
rm -f "$t5_root/var/lib/pangolin/site-layout"

# (2, 4, 5) systemd conversion success: import byte-for-byte mode 0600, stop
# legacy before @default starts, retire legacy after verification, write the
# marker, and never invoke the single-instance CLI install.
t5_reset_root
t5_legacy_systemd
t5_legacy_env
t5_updater
printf '#!/bin/sh\n. /etc/pangolin/pangolin-site.env\nexec pangolin up site\n' \
  >"$t5_root/usr/local/bin/pangolin-site-start"
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
: >"$FAKE_LOG"
conv_out="$(convert_site_layout systemd "$tmpd/flags-on" 2>"$tmpd/conv.err")" ||
  fail "systemd conversion should succeed: $(cat "$tmpd/conv.err")"
[[ -f "$t5_default_cfg" ]] || fail "sites/default.json should be imported"
cmp -s "$t5_root/etc/pangolin/site.json" "$t5_default_cfg" || fail "import must be byte-for-byte"
assert_eq "600" "$(stat -c '%a' "$t5_default_cfg")"
[[ -f "$t5_root/etc/pangolin/site.json" ]] || fail "conversion must keep the legacy site.json"
stop_line="$(grep -n '^systemctl stop pangolin-site$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
enable_line="$(grep -n '^systemctl enable --now pangolin-site@default$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ -n "$stop_line" && -n "$enable_line" ]] || fail "conversion must stop legacy and start @default"
[[ "$stop_line" -lt "$enable_line" ]] || fail "legacy must stop before @default starts"
if grep -q 'pangolin service install' "$FAKE_LOG"; then
  fail "template conversion must not call the single-instance CLI install"
fi
if grep -q '^systemctl start pangolin-site$' "$FAKE_LOG"; then
  fail "a successful conversion must not start the legacy service"
fi
[[ ! -e "$t5_root/etc/systemd/system/pangolin-site.service" ]] ||
  fail "a verified conversion must retire the legacy unit"
[[ ! -e "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service" ]] ||
  fail "a verified conversion must remove the legacy wants symlink"
[[ ! -e "$t5_root/etc/pangolin/pangolin-site.env" ]] ||
  fail "a verified conversion must remove the legacy site env"
[[ ! -e "$t5_root/usr/local/bin/pangolin-site-start" ]] ||
  fail "a verified conversion must remove the legacy-content wrapper"
grep -q 'exec /usr/local/bin/pangolin update' "$t5_root/usr/bin/update-pangolin-site" ||
  fail "the updater keeps its compatibility wrapper"
t5_backup="$(find "$t5_root/var/lib/pangolin/backup" -name pangolin-site.env -print -quit)"
[[ -n "$t5_backup" ]] || fail "conversion must back up the legacy env before removing it"
grep -q '^SITE_SECRET=oldsecret$' "$t5_backup" || fail "the env backup must keep the original"
assert_eq "600" "$(stat -c '%a' "$t5_backup")"
[[ -f "$t5_root/var/lib/pangolin/site-layout" ]] || fail "conversion must record the marker"
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
assert_eq "644" "$(stat -c '%a' "$t5_root/var/lib/pangolin/site-layout")"
for secret in s3cr3t-static oldsecret; do
  case "$conv_out$(cat "$tmpd/conv.err")" in
  *"$secret"*) fail "conversion must not print the secret $secret" ;;
  esac
done

# (3) Newt static credentials convert into sites/default.json when no JSON
# exists, and a fresh root with no legacy service issues no legacy stop.
t5_reset_root
LEGACY_NEWT_ID=nid
LEGACY_NEWT_SECRET=nsec
LEGACY_ENDPOINT=https://p.example
write_private_file "$(site_config_path orga)" \
  "$(site_config_static "https://p.example" idorg secorg)"
: >"$FAKE_LOG"
# The fake reports an inactive legacy service, as a host without one really
# would, so retire must not act on it.
FAKE_INACTIVE_UNIT=pangolin-site convert_site_layout systemd "" orga ||
  fail "Newt conversion should succeed"
[[ -f "$t5_default_cfg" ]] || fail "Newt credentials must import to the default path"
python3 - "$t5_default_cfg" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {"endpoint": "https://p.example", "id": "nid", "secret": "nsec"}, d
PY
assert_eq "600" "$(stat -c '%a' "$t5_default_cfg")"
grep -q '^systemctl enable --now pangolin-site@default$' "$FAKE_LOG" ||
  fail "Newt conversion must start @default"
grep -q '^systemctl enable --now pangolin-site@orga$' "$FAKE_LOG" ||
  fail "Newt conversion must start the requested slug"
if grep -q '^systemctl stop pangolin-site$' "$FAKE_LOG"; then
  fail "a host with no legacy service must not receive a stop"
fi
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
LEGACY_NEWT_ID=""
LEGACY_NEWT_SECRET=""
LEGACY_ENDPOINT=""

# (2b) A provisioning-key and native-state config is copied byte-for-byte; the
# import runs even when the instance install later fails.
t5_reset_root
prov_native="$(site_config_provisioning "https://p.example" "spk-1.secret" "pve-1" 1 1 pangorga pangmorga)"
write_private_file "$t5_root/etc/pangolin/site.json" "$prov_native"
conv_rc=0
(
  install_site_systemd_slug() {
    echo "stub: instance failed" >&2
    return 1
  }
  convert_site_layout systemd "$tmpd/flags-on" default
) >/dev/null 2>&1 || conv_rc=$?
[[ "$conv_rc" -ne 0 ]] || fail "conversion must fail when @default cannot install"
cmp -s "$t5_root/etc/pangolin/site.json" "$t5_default_cfg" ||
  fail "a provisioning import must stay byte-for-byte"
grep -q '"provisioningKey"' "$t5_default_cfg" || fail "provisioning key must be preserved"
grep -q '"nativeMain":true' "$t5_default_cfg" || fail "native state must be preserved"
if [[ -e "$t5_root/var/lib/pangolin/site-layout" ]]; then
  fail "the marker must not exist when @default never verified"
fi

# (6) A failing @default restores the legacy files, restarts the legacy
# service, removes the half-built default instance, and never starts extras.
t5_reset_root
t5_legacy_systemd
t5_legacy_env
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
write_private_file "$(site_config_path orgb)" \
  "$(site_config_static "https://p.example" idb secb)"
: >"$FAKE_LOG"
conv_rc=0
FAKE_INACTIVE_UNIT='pangolin-site@default' \
  convert_site_layout systemd "$tmpd/flags-on" default orgb >/dev/null 2>&1 || conv_rc=$?
[[ "$conv_rc" -ne 0 ]] || fail "conversion must fail when @default never activates"
grep -q '^systemctl stop pangolin-site$' "$FAKE_LOG" || fail "legacy must be stopped first"
grep -q '^systemctl disable pangolin-site@default$' "$FAKE_LOG" ||
  fail "the failed default instance must be disabled so it cannot race legacy at boot"
grep -q '^systemctl start pangolin-site$' "$FAKE_LOG" ||
  fail "an active legacy service must be restarted after the failed default"
if grep -q 'pangolin-site@orgb' "$FAKE_LOG"; then
  fail "a failed default must not start extra slugs"
fi
[[ -f "$t5_root/etc/systemd/system/pangolin-site.service" ]] ||
  fail "a failed default must keep the legacy unit (restore, never retire)"
[[ "$(cat "$t5_root/etc/systemd/system/pangolin-site.service")" == "UNIT-ORIGINAL" ]] ||
  fail "the restored legacy unit must match the backup"
[[ -L "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service" ]] ||
  fail "the failed path must restore the legacy wants symlink"
[[ -f "$t5_root/etc/pangolin/pangolin-site.env" ]] ||
  fail "the failed path must keep the legacy env (cleanup only after success)"
[[ -f "$(site_config_path orgb)" ]] || fail "an unattempted slug config must survive"
if [[ -e "$t5_root/var/lib/pangolin/site-layout" ]]; then
  fail "the marker must not exist after a failed default"
fi
# The failed restore leaves the legacy env; the backup dir holds a copy.
[[ -n "$(find "$t5_root/var/lib/pangolin/backup" -name pangolin-site.env -print -quit)" ]] ||
  fail "conversion must back up the legacy env before attempting changes"

# (7) An extra slug failure removes only that instance and leaves default.
t5_reset_root
t5_legacy_systemd
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
write_private_file "$(site_config_path orgb)" \
  "$(site_config_static "https://p.example" idb secb)"
: >"$FAKE_LOG"
conv_rc=0
FAKE_INACTIVE_UNIT='pangolin-site@orgb' \
  convert_site_layout systemd "$tmpd/flags-on" default orgb >/dev/null 2>&1 || conv_rc=$?
[[ "$conv_rc" -ne 0 ]] || fail "a failed extra slug must fail the run"
grep -q '^systemctl enable --now pangolin-site@default$' "$FAKE_LOG" ||
  fail "default must install before extra slugs"
orgb_enable="$(grep -n '^systemctl enable --now pangolin-site@orgb$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
orgb_disable="$(grep -n '^systemctl disable pangolin-site@orgb$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ -n "$orgb_enable" && -n "$orgb_disable" ]] || fail "the failed slug must be enabled then disabled"
[[ "$orgb_enable" -lt "$orgb_disable" ]] || fail "the failed slug must be removed after its failure"
if grep -qE '^systemctl (stop|disable) pangolin-site@default$' "$FAKE_LOG"; then
  fail "a failed extra slug must leave the verified default running"
fi
if grep -q '^systemctl start pangolin-site$' "$FAKE_LOG"; then
  fail "default verified, so the legacy service must not be started again"
fi
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
[[ ! -e "$t5_root/etc/systemd/system/pangolin-site.service" ]] ||
  fail "a verified default must still retire the legacy unit"
[[ -f "$(site_config_path orgb)" ]] || fail "the failed slug config must stay for diagnostics"

# (8) A rerun with the template marker is a quiet no-op: no re-import and no
# rewrite of the default instance.
write_private_file "$t5_root/etc/pangolin/site.json" "SENTINEL-LEGACY"
write_private_file "$t5_default_cfg" "SENTINEL-DEFAULT"
: >"$FAKE_LOG"
convert_site_layout systemd "" default orgb || fail "a rerun on template state should succeed"
[[ "$(cat "$t5_default_cfg")" == "SENTINEL-DEFAULT" ]] ||
  fail "a rerun must not re-import or rewrite the default config"
[[ "$(cat "$t5_root/etc/pangolin/site.json")" == "SENTINEL-LEGACY" ]] ||
  fail "a rerun must not touch the legacy site.json"
[[ ! -s "$FAKE_LOG" ]] || fail "a rerun on template state must not touch services"
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"

# (9) A single non-default slug with no flag still triggers conversion.
t5_reset_root
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
write_private_file "$(site_config_path orga)" \
  "$(site_config_static "https://p.example" idorg secorg)"
convert_site_layout systemd "" orga || fail "a nondefault slug must trigger conversion"
cmp -s "$t5_root/etc/pangolin/site.json" "$t5_default_cfg" ||
  fail "a nondefault trigger must still import the default config"
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"

# (10) A mixed layout (interrupted conversion) is detected and repaired
# without deleting configs or existing backups, even with only default asked.
t5_reset_root
t5_legacy_systemd
t5_legacy_env
write_private_file "$t5_root/etc/pangolin/site.json" \
  "$(site_config_static "https://p.example" idA secretA)"
printf '[Unit]\n' >"$t5_root/etc/systemd/system/pangolin-site@.service"
write_private_file "$t5_default_cfg" "$(site_config_static "https://p.example" idM secretM)"
write_private_file "$(site_config_path other)" "$(site_config_static "https://p.example" idO secretO)"
write_private_file "$(site_config_path orgc)" "$(site_config_static "https://p.example" idC secretC)"
mkdir -p "$t5_root/var/lib/pangolin/backup/20200101-000000"
printf 'name\t/original\n' >"$t5_root/var/lib/pangolin/backup/20200101-000000/manifest"
printf 'OLD\n' >"$t5_root/var/lib/pangolin/backup/20200101-000000/name"
default_before="$(cat "$t5_default_cfg")"
site_before="$(cat "$t5_root/etc/pangolin/site.json")"
assert_eq mixed "$(site_conversion_state)"
: >"$FAKE_LOG"
convert_site_layout systemd "" default orgc || fail "mixed layout must repair cleanly"
[[ "$(cat "$t5_default_cfg")" == "$default_before" ]] ||
  fail "repair must not rewrite an existing default config"
[[ "$(cat "$t5_root/etc/pangolin/site.json")" == "$site_before" ]] ||
  fail "repair must keep the legacy site.json"
[[ -f "$(site_config_path other)" ]] || fail "repair must keep unrelated slug configs"
[[ -f "$t5_root/var/lib/pangolin/backup/20200101-000000/name" ]] ||
  fail "repair must keep previous backups"
[[ ! -e "$t5_root/etc/systemd/system/pangolin-site.service" ]] ||
  fail "repair must retire the leftover legacy unit"
[[ ! -e "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site.service" ]] ||
  fail "repair must remove the legacy wants symlink"
[[ -f "$t5_root/etc/systemd/system/pangolin-site@.service" ]] ||
  fail "repair must keep the shared template"
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
grep -q '^systemctl enable --now pangolin-site@orgc$' "$FAKE_LOG" ||
  fail "repair must still install the requested extra slug"

# (11) OpenRC conversion: stop the legacy service before the default slug is
# added to the runlevel; retire init, wrapper, and runlevel entry after.
t5_reset_root
t5_legacy_openrc
t5_legacy_env
t5_updater
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
: >"$FAKE_LOG"
conv_out="$(convert_site_layout openrc "$tmpd/flags-on" 2>/dev/null)" ||
  fail "OpenRC conversion should succeed"
rc_stop="$(grep -n '^rc-service pangolin-site stop$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
rc_add="$(grep -n '^rc-update add pangolin-site-default default$' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
[[ -n "$rc_stop" && -n "$rc_add" ]] || fail "OpenRC must stop legacy and add the default slug"
[[ "$rc_stop" -lt "$rc_add" ]] || fail "OpenRC legacy must stop before the slug is added"
cmp -s "$t5_root/etc/pangolin/site.json" "$t5_default_cfg" ||
  fail "OpenRC import must be byte-for-byte"
[[ ! -e "$t5_root/etc/init.d/pangolin-site" ]] || fail "OpenRC retire must remove the legacy init"
[[ ! -e "$t5_root/usr/local/bin/pangolin-site-start" ]] ||
  fail "OpenRC retire must remove the legacy wrapper"
[[ ! -e "$t5_root/etc/runlevels/default/pangolin-site" ]] ||
  fail "OpenRC retire must remove the legacy runlevel entry"
[[ -f "$t5_root/etc/init.d/pangolin-site-default" ]] || fail "the default slug unit must exist"
[[ -f "$t5_root/usr/local/bin/pangolin-site-default-start" ]] || fail "the default wrapper must exist"
grep -q "CONFIG_FILE='/etc/pangolin/sites/default.json'" \
  "$t5_root/usr/local/bin/pangolin-site-default-start" ||
  fail "the default wrapper must use the production config path"
[[ ! -e "$t5_root/etc/pangolin/pangolin-site.env" ]] || fail "the legacy env must be removed"
assert_eq "template" "$(cat "$t5_root/var/lib/pangolin/site-layout")"
case "$conv_out" in
*"s3cr3t-static"* | *"oldsecret"*) fail "OpenRC conversion must not print secrets" ;;
esac

# OpenRC default failure: remove only the half-built default instance, keep
# the legacy files, restart the active legacy service, and skip the marker.
t5_reset_root
t5_legacy_openrc
t5_legacy_env
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
: >"$FAKE_LOG"
conv_rc=0
FAKE_INACTIVE_UNIT='pangolin-site-default' \
  convert_site_layout openrc "$tmpd/flags-on" default orgb >/dev/null 2>&1 || conv_rc=$?
[[ "$conv_rc" -ne 0 ]] || fail "an OpenRC default failure must fail the run"
grep -q '^rc-update del pangolin-site-default default$' "$FAKE_LOG" ||
  fail "the failed default instance must be removed from the runlevel"
if grep -q 'pangolin-site-orgb' "$FAKE_LOG"; then
  fail "a failed default must not start extra OpenRC slugs"
fi
[[ -f "$t5_root/etc/init.d/pangolin-site" ]] || fail "the legacy init must survive a failed default"
[[ -f "$t5_root/usr/local/bin/pangolin-site-start" ]] ||
  fail "the legacy wrapper must survive a failed default"
grep -q '^rc-service pangolin-site start$' "$FAKE_LOG" ||
  fail "an active legacy service must be restarted after the failed default"
[[ ! -e "$t5_root/etc/init.d/pangolin-site-default" ]] ||
  fail "the failed default unit file must be removed"
[[ ! -e "$t5_root/usr/local/bin/pangolin-site-default-start" ]] ||
  fail "the failed default wrapper must be removed"
[[ ! -e "$t5_root/var/log/pangolin-site-default.log" ]] ||
  fail "the failed default log must be removed"
if [[ -e "$t5_root/var/lib/pangolin/site-layout" ]]; then fail "no marker after a failure"; fi

# remove_site_openrc_slug and uninstall_site_slug: stop/disable, then remove
# the slug's unit, wrapper, and log; keep the config and shared logrotate.
t5_reset_root
printf '#!/sbin/openrc-run\n' >"$t5_root/etc/init.d/pangolin-site-rem1"
printf '#!/bin/sh\n' >"$t5_root/usr/local/bin/pangolin-site-rem1-start"
printf 'log\n' >"$t5_root/var/log/pangolin-site-rem1.log"
ln -sf "$t5_root/etc/init.d/pangolin-site-rem1" "$t5_root/etc/runlevels/default/pangolin-site-rem1"
printf 'lr\n' >"$t5_root/etc/logrotate.d/pangolin"
write_private_file "$(site_config_path rem1)" "$t5_cred"
: >"$FAKE_LOG"
uninstall_site_slug openrc rem1 || fail "OpenRC uninstall should succeed"
grep -q '^rc-service pangolin-site-rem1 stop$' "$FAKE_LOG" || fail "uninstall must stop the slug"
grep -q '^rc-update del pangolin-site-rem1 default$' "$FAKE_LOG" || fail "uninstall must disable the slug"
[[ ! -e "$t5_root/etc/init.d/pangolin-site-rem1" ]] || fail "uninstall must remove the unit"
[[ ! -e "$t5_root/usr/local/bin/pangolin-site-rem1-start" ]] || fail "uninstall must remove the wrapper"
[[ ! -e "$t5_root/var/log/pangolin-site-rem1.log" ]] || fail "uninstall must remove the log"
[[ -f "$(site_config_path rem1)" ]] || fail "uninstall must keep the per-slug config"
[[ -f "$t5_root/etc/logrotate.d/pangolin" ]] || fail "uninstall must keep the shared logrotate file"
# Idempotent repeat: no runlevel entry means no rc-update del and no error.
: >"$FAKE_LOG"
uninstall_site_slug openrc rem1 || fail "OpenRC uninstall must be idempotent"
if grep -q '^rc-update del pangolin-site-rem1 default$' "$FAKE_LOG"; then
  fail "a repeated uninstall must not re-del an absent runlevel entry"
fi
# systemd branch: disable the instance, keep the shared template.
printf '[Unit]\n' >"$t5_root/etc/systemd/system/pangolin-site@.service"
ln -sf ../pangolin-site@.service "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site@u1.service"
: >"$FAKE_LOG"
uninstall_site_slug systemd u1 || fail "systemd uninstall should succeed"
grep -q '^systemctl disable pangolin-site@u1$' "$FAKE_LOG" || fail "systemd uninstall must disable"
[[ ! -e "$t5_root/etc/systemd/system/multi-user.target.wants/pangolin-site@u1.service" ]] ||
  fail "systemd uninstall must remove the instance symlink"
[[ -f "$t5_root/etc/systemd/system/pangolin-site@.service" ]] ||
  fail "systemd uninstall must keep the shared template"
if uninstall_site_slug bogus u1 >/dev/null 2>&1; then fail "unknown backend must fail"; fi
if uninstall_site_slug openrc "" >/dev/null 2>&1; then fail "an empty slug must fail"; fi
if convert_site_layout bogus "" default >/dev/null 2>&1; then fail "unknown backend conversion must fail"; fi
if convert_site_layout systemd "" 'bad slug' >/dev/null 2>&1; then fail "invalid slug must fail"; fi
if convert_site_layout systemd "" host >/dev/null 2>&1; then fail "reserved host slug must fail"; fi

# A single default with no request on an unconverted host converts nothing.
t5_reset_root
t5_legacy_systemd
write_private_file "$t5_root/etc/pangolin/site.json" "$t5_cred"
: >"$FAKE_LOG"
convert_site_layout systemd "$tmpd/flags-off" default || fail "no trigger must return success"
[[ ! -s "$FAKE_LOG" ]] || fail "no trigger must not touch services"
[[ ! -e "$t5_root/etc/systemd/system/pangolin-site@.service" ]] ||
  fail "no trigger must not write the template"
if [[ -e "$t5_root/var/lib/pangolin/site-layout" ]]; then fail "no trigger must not mark template"; fi

rm -rf "$tmpd"
export PATH="$old_path"
export PANGOLIN_ROOT="$old_pangolin_root"
export PANGOLIN_BIN="$old_pangolin_bin"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
if [[ -n "$old_fake_inactive_unit" ]]; then export FAKE_INACTIVE_UNIT="$old_fake_inactive_unit"; else unset FAKE_INACTIVE_UNIT; fi
export LEGACY_NEWT_ID="$old_newt_id"
export LEGACY_NEWT_SECRET="$old_newt_secret"
export LEGACY_ENDPOINT="$old_newt_endpoint"
unset PANGOLIN_SERVICE_ATTEMPTS PANGOLIN_SERVICE_DELAY

echo "Multi-site Task 5 tests passed"
