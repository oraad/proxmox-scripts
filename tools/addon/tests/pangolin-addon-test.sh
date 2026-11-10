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
