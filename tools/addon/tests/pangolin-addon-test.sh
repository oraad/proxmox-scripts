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
[[ "$("$PANGOLIN_BIN" version)" == "0.21.0" ]] || fail "binary version"
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
[[ "$("$PANGOLIN_BIN" version)" == "0.21.0" ]] || fail "refused install must keep the binary"

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
for c in rc-update rc-service supervise-daemon pangolin; do
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
if grep -q 'csecret' "$client_unit" "$client_wrapper"; then
  fail "client unit and wrapper must not contain the secret"
fi
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
