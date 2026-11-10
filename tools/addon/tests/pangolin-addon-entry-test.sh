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

# Site native toggles: booleans are 0/1 only and interface names are validated
# before any side effect.
validate_native_flag 0 || { echo "native flag 0" >&2; exit 1; }
validate_native_flag 1 || { echo "native flag 1" >&2; exit 1; }
for flag in true yes ""; do
  if validate_native_flag "$flag" >/dev/null 2>&1; then
    echo "native flag [$flag] should fail" >&2
    exit 1
  fi
done
for name in "bad name" "bad/name" "1bad" "abcdefghijklmnop"; do
  if validate_interface_name "$name" >/dev/null 2>&1; then
    echo "interface [$name] should fail" >&2
    exit 1
  fi
done
validate_interface_name pangolin || { echo "default interface should pass" >&2; exit 1; }
validate_interface_name "wg0.1-test_2" || { echo "dotted interface should pass" >&2; exit 1; }
validate_interface_name "abcdefghijklmno" || { echo "15-character interface should pass" >&2; exit 1; }
if _validate_native_args "" 0 pangolin pangolin >/dev/null 2>&1; then
  echo "empty native flag should fail" >&2
  exit 1
fi

os_supported debian 12 || { echo "debian 12 should pass" >&2; exit 1; }
os_supported debian 13 || { echo "debian 13 should pass" >&2; exit 1; }
os_supported debian 12.5 || { echo "debian 12.5 should pass" >&2; exit 1; }
if os_supported debian 11 >/dev/null 2>&1; then echo "debian 11 should fail" >&2; exit 1; fi
os_supported ubuntu 22.04 || { echo "ubuntu 22.04 should pass" >&2; exit 1; }
os_supported ubuntu 24.04 || { echo "ubuntu 24.04 should pass" >&2; exit 1; }
os_supported ubuntu 22.04.3 || { echo "ubuntu 22.04.3 should pass" >&2; exit 1; }
if os_supported ubuntu 20.04 >/dev/null 2>&1; then echo "ubuntu 20.04 should fail" >&2; exit 1; fi
os_supported alpine 3.20 || { echo "alpine 3.20 should pass" >&2; exit 1; }
os_supported alpine 3.20.3 || { echo "alpine 3.20.3 should pass" >&2; exit 1; }
if os_supported alpine 3.19 >/dev/null 2>&1; then echo "alpine 3.19 should fail" >&2; exit 1; fi
if os_supported arch 1 >/dev/null 2>&1; then echo "unknown distro should fail" >&2; exit 1; fi
if os_supported debian "" >/dev/null 2>&1; then echo "missing version should fail" >&2; exit 1; fi

# The LXC path reads /etc/os-release through pct and rejects an old target.
os_tmpd="$(mktemp -d)"
mkdir -p "$os_tmpd/bin"
cat >"$os_tmpd/bin/pct" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"cat /etc/os-release"*)
  printf 'ID=%s\nVERSION_ID="%s"\n' "${FAKE_OS_ID:-debian}" "${FAKE_OS_VERSION:-12}"
  ;;
esac
EOF
chmod 755 "$os_tmpd/bin/pct"
old_path="$PATH"
export PATH="$os_tmpd/bin:$PATH"
export FAKE_OS_ID=debian FAKE_OS_VERSION=11
if os_err="$(_validate_target_os 101 2>&1)"; then
  echo "debian 11 target should fail" >&2
  exit 1
fi
case "$os_err" in
*"Unsupported target OS"*"Debian 12+"*) ;;
*) echo "unsupported OS message: $os_err" >&2; exit 1 ;;
esac
export FAKE_OS_VERSION=12
_validate_target_os 101 >/dev/null || { echo "debian 12 target should pass" >&2; exit 1; }
unset FAKE_OS_ID FAKE_OS_VERSION
export PATH="$old_path"
rm -rf "$os_tmpd"

# Host client TUN probe: an existing device passes, a missing one fails.
tun_tmpd="$(mktemp -d)"
: >"$tun_tmpd/tun"
_ensure_host_tun "$tun_tmpd/tun" || { echo "existing tun should pass" >&2; exit 1; }
if _ensure_host_tun "$tun_tmpd/missing-tun" >/dev/null 2>&1; then
  echo "missing tun should fail" >&2
  exit 1
fi
rm -rf "$tun_tmpd"

# TUN is needed by client mode and by either site native mode, never by a plain
# userspace site tunnel.
tun_required 1 0 0 || { echo "client mode needs TUN" >&2; exit 1; }
tun_required 0 1 0 || { echo "native site mode needs TUN" >&2; exit 1; }
tun_required 0 0 1 || { echo "native main site mode needs TUN" >&2; exit 1; }
if tun_required 0 0 0; then echo "plain site must not need TUN" >&2; exit 1; fi

# Provisioning-key warnings cover the paid tier and reconfigure second site.
if ! (
  msg_warn() { printf 'WARN:%s\n' "$*" >&2; }
  var_site_provisioning_key="spk-x"
  warnings="$(_warn_provisioning_risks 1 1 2>&1)"
  case "$warnings" in
  *tier3*"approve new sites"*"second server-side site"*) ;;
  *)
    echo "provisioning warnings missing: $warnings" >&2
    exit 1
    ;;
  esac
  var_site_provisioning_key=""
  [[ -z "$(_warn_provisioning_risks 0 1 2>&1)" ]] || {
    echo "warnings without a provisioning key" >&2
    exit 1
  }
); then
  exit 1
fi

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
[[ "$(stat -c '%a' "$dir")" == "700" ]] || { echo "answers dir mode" >&2; exit 1; }
[[ "$(stat -c '%a' "$dir/site.json")" == "600" ]] || { echo "site config mode" >&2; exit 1; }

# Task 12: build_site_answers passes the native toggles through to the config.
build_site_answers "$dir" "https://p.example" - - id secret 1 1 pangolin pangolin-main ||
  { echo "native site answers" >&2; exit 1; }
python3 - "$dir/site.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["native"] is True and d["interface"] == "pangolin", d
assert d["nativeMain"] is True and d["interfaceMain"] == "pangolin-main", d
PY
[[ "$(stat -c '%a' "$dir/site.json")" == "600" ]] || { echo "native config mode" >&2; exit 1; }

# Invalid native values fail before the answers file is written.
bad_dir="$dir/bad"
if build_site_answers "$bad_dir" "https://p.example" - - id secret yes 0 pangolin pangolin \
  >/dev/null 2>&1; then
  echo "invalid native flag should fail" >&2
  exit 1
fi
if build_site_answers "$bad_dir" "https://p.example" - - id secret 1 0 "bad name" pangolin \
  >/dev/null 2>&1; then
  echo "invalid native interface should fail" >&2
  exit 1
fi
[[ ! -e "$bad_dir/site.json" ]] || { echo "failed validation must not write answers" >&2; exit 1; }

# Both enabled with the CLI default name resolves the main tunnel to
# pangolin-main and prints a notice; any other shared name fails.
if ! native_notice="$(
  var_site_native=1 var_site_native_main=1
  var_site_interface=pangolin var_site_interface_main=pangolin
  _resolve_site_native 2>&1 || exit 1
  [[ "$var_site_native" == 1 && "$var_site_native_main" == 1 ]] || exit 1
  [[ "$var_site_interface" == pangolin ]] || exit 1
  [[ "$var_site_interface_main" == pangolin-main ]] || exit 1
)"; then
  echo "both default native names must resolve" >&2
  exit 1
fi
case "$native_notice" in
*pangolin-main*) ;;
*)
  echo "default native name resolution should print a notice: $native_notice" >&2
  exit 1
  ;;
esac

equal_rc=0
equal_out="$(
  var_site_native=1 var_site_native_main=1
  var_site_interface=wg0 var_site_interface_main=wg0
  _resolve_site_native 2>&1
)" || equal_rc=$?
[[ "$equal_rc" -ne 0 ]] || { echo "equal custom native names should fail" >&2; exit 1; }
case "$equal_out" in
*distinct*) ;;
*)
  echo "equal native names should ask for distinct names: $equal_out" >&2
  exit 1
  ;;
esac

# An enabled native mode is accepted without new answers only when the existing
# site configuration already holds the requested keys and names.
native_root="$(mktemp -d)"
mkdir -p "$native_root/etc/pangolin"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$native_root"
write_private_file "$native_root/etc/pangolin/site.json" \
  "$(site_config_static https://p.example id secret 1 1 pangolin pangolin-main)"
(
  var_site_native=1
  var_site_native_main=1
  var_site_interface=pangolin
  var_site_interface_main=pangolin-main
  _native_config_possible host 0
) || { echo "a matching native config should allow reuse" >&2; exit 1; }

if (
  var_site_native=1
  var_site_native_main=1
  var_site_interface=pangolin
  var_site_interface_main=wg-main
  _native_config_possible host 0
); then
  echo "a mismatched native interface should fail reuse" >&2
  exit 1
fi

rm -f "$native_root/etc/pangolin/site.json"
if (
  var_site_native=1
  var_site_native_main=0
  var_site_interface=pangolin
  _native_config_possible host 0
); then
  echo "a missing site config should fail native reuse" >&2
  exit 1
fi

# Plain site reuse is unchanged and needs no target config.
(
  var_site_native=0
  var_site_native_main=0
  _native_config_possible host 0
) || { echo "plain site reuse should pass" >&2; exit 1; }

# New answers never read the target.
(
  var_site_native=1
  var_site_native_main=1
  var_site_interface=pangolin
  var_site_interface_main=pangolin-main
  _native_config_possible host 1
) || { echo "new answers should pass without a target config" >&2; exit 1; }

# A reused LXC configuration is read through pct and must match as well.
lxc_tmpd="$(mktemp -d)"
mkdir -p "$lxc_tmpd/bin"
cat >"$lxc_tmpd/bin/pct" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"cat /etc/pangolin/site.json"*) printf '%s\n' "$FAKE_SITE_CONFIG" ;;
esac
EOF
chmod 755 "$lxc_tmpd/bin/pct"
if ! (
  export PATH="$lxc_tmpd/bin:$PATH"
  export FAKE_SITE_CONFIG='{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangolin"}'
  var_site_native=1
  var_site_native_main=0
  var_site_interface=pangolin
  _native_config_possible 101 0
); then
  echo "a matching LXC native config should allow reuse" >&2
  exit 1
fi
if (
  export PATH="$lxc_tmpd/bin:$PATH"
  export FAKE_SITE_CONFIG='{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"wg0"}'
  var_site_native=1
  var_site_native_main=0
  var_site_interface=pangolin
  _native_config_possible 101 0
); then
  echo "a mismatched LXC native config should fail reuse" >&2
  exit 1
fi
rm -rf "$lxc_tmpd"
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$native_root"

fetch_payload "$dir/payload.sh"
cmp -s "$PANGOLIN_PAYLOAD" "$dir/payload.sh" || { echo "payload copy" >&2; exit 1; }
[[ "$(stat -c '%a' "$dir/payload.sh")" == "600" ]] || { echo "payload mode" >&2; exit 1; }

build_client_answers "$dir" "https://p.example" cid csecret
grep -q "PANGOLIN_CLIENT_ID='cid'" "$dir/client.env" || { echo "client answers" >&2; exit 1; }
[[ "$(stat -c '%a' "$dir/client.env")" == "600" ]] || { echo "client env mode" >&2; exit 1; }

# Shell metacharacters in credentials must survive a source of client.env.
hostile="s3cr\$et 'q' \"d\" \`id\` ; #hash
line2"
build_client_answers "$dir" "https://p.example" "$hostile" "$hostile"
(
  # shellcheck disable=SC1090,SC1091
  source "$dir/client.env"
  [[ "$PANGOLIN_CLIENT_ID" == "$hostile" ]] || {
    echo "hostile client id" >&2
    exit 1
  }
  [[ "$PANGOLIN_CLIENT_SECRET" == "$hostile" ]] || {
    echo "hostile client secret" >&2
    exit 1
  }
  [[ "$PANGOLIN_ENDPOINT" == "https://p.example" ]] || {
    echo "hostile client endpoint" >&2
    exit 1
  }
) || { echo "hostile client env" >&2; exit 1; }
rm -rf "$dir"

# Task 10: transport and LXC tags. The payload and every answers file are
# pushed with explicit modes; no secret travels in an argument value.
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
old_path="$PATH"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
printf '#!/bin/sh\n' >"$tmpd/payload.sh"
printf 'flags\n' >"$tmpd/site.json"
push_payload 101 "$tmpd/payload.sh" "$tmpd"
grep -q 'pct push 101' "$FAKE_LOG" || { echo "push missing" >&2; exit 1; }
grep -q 'pct push 101 .*payload.sh /root/.pangolin-addon/payload.sh --perms 700' "$FAKE_LOG" ||
  { echo "payload push mode" >&2; exit 1; }
grep -q 'pct push 101 .*site.json /root/.pangolin-addon/site.json --perms 600' "$FAKE_LOG" ||
  { echo "answers push mode" >&2; exit 1; }
if grep -q 'pct exec 101 -- env' "$FAKE_LOG"; then
  echo "push must not send an environment" >&2
  exit 1
fi
apply_lxc_tags 101 1 1
grep -q 'pct set 101 -tags' "$FAKE_LOG" || { echo "tags missing" >&2; exit 1; }
grep -q 'pct set 101 -tags old;pangolin-site;pangolin-client' "$FAKE_LOG" ||
  { echo "tag content" >&2; exit 1; }
rm -rf "$tmpd"
export PATH="$old_path"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi

# pct push without --perms support falls back to chmod inside the container.
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/bin"
cat >"$tmpd/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$FAKE_LOG"
case "$*" in
  *--perms*) exit 1 ;;
  exec*) exit 0 ;;
esac
exit 0
EOF
chmod 755 "$tmpd/bin/pct"
old_path="$PATH"
old_fake_log="${FAKE_LOG:-}"
export PATH="$tmpd/bin:$PATH"
export FAKE_LOG="$tmpd/log"
printf '#!/bin/sh\n' >"$tmpd/payload.sh"
printf 'flags\n' >"$tmpd/site.json"
push_payload 102 "$tmpd/payload.sh" "$tmpd" ||
  { echo "push fallback should succeed" >&2; exit 1; }
grep -q 'pct exec 102 -- chmod 700 /root/.pangolin-addon/payload.sh' "$FAKE_LOG" ||
  { echo "payload chmod fallback" >&2; exit 1; }
grep -q 'pct exec 102 -- chmod 600 /root/.pangolin-addon/site.json' "$FAKE_LOG" ||
  { echo "answers chmod fallback" >&2; exit 1; }
rm -rf "$tmpd"
export PATH="$old_path"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi

# Only components recorded as verified are tagged on an LXC target.
tagd="$(mktemp -d)"
mkdir -p "$tagd/bin"
printf 'site\n' >"$tagd/verified"
cat >"$tagd/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$FAKE_LOG"
case "$1" in
config) printf 'tags: old;pangolin-cli\n' ;;
exec)
  case "$*" in
  *"/verified"*) cat "$FAKE_VERIFIED_FILE" ;;
  *) exit 0 ;;
  esac
  ;;
esac
EOF
chmod 755 "$tagd/bin/pct"
old_path="$PATH"
old_fake_log="${FAKE_LOG:-}"
old_fake_verified="${FAKE_VERIFIED_FILE:-}"
export PATH="$tagd/bin:$PATH"
export FAKE_LOG="$tagd/log"
export FAKE_VERIFIED_FILE="$tagd/verified"
_apply_verified_tags 101 "$tagd"
[[ "$VERIFIED_SITE" == "1" && "$VERIFIED_CLIENT" == "0" ]] ||
  { echo "verified marker should select site only" >&2; exit 1; }
grep -q 'pct set 101 -tags old;pangolin-site' "$FAKE_LOG" ||
  { echo "partial tags should include site" >&2; exit 1; }
if grep -q 'pct set .*pangolin-client' "$FAKE_LOG"; then
  echo "failed client must not be tagged" >&2
  exit 1
fi
printf 'client\n' >"$tagd/verified"
_apply_verified_tags host "$tagd"
[[ "$VERIFIED_SITE" == "0" && "$VERIFIED_CLIENT" == "1" ]] ||
  { echo "host marker should select client only" >&2; exit 1; }
export PATH="$old_path"
if [[ -n "$old_fake_log" ]]; then export FAKE_LOG="$old_fake_log"; else unset FAKE_LOG; fi
if [[ -n "$old_fake_verified" ]]; then
  export FAKE_VERIFIED_FILE="$old_fake_verified"
else
  unset FAKE_VERIFIED_FILE
fi
rm -rf "$tagd"

# Partial result: site succeeds, client fails. Both components are tried and
# the run fails, while the site install is not rolled back.
tmpd2="$(mktemp -d)"
mkdir -p "$tmpd2/answers" "$tmpd2/root"
printf 'SITE=1\nCLIENT=1\nRECONFIGURE=0\nTARGET=host\n' >"$tmpd2/answers/flags"
write_private_file "$tmpd2/answers/site.json" "$(site_config_static https://p.example id sec)"
write_private_file "$tmpd2/answers/client.env" "PANGOLIN_CLIENT_ID=cid
PANGOLIN_CLIENT_SECRET=csec
PANGOLIN_ENDPOINT=https://p.example"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd2/root"
if ! (
  site_called=0
  client_called=0
  client_args=""
  newt_cleaned=0
  stopped=""
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  cleanup_legacy_newt() { newt_cleaned=1; }
  wait_for_provisioning() { :; }
  stop_service() { stopped="$2"; }
  install_site_systemd() { site_called=1; }
  install_client_systemd() {
    client_called=1
    client_args="$1 $2 $3"
    return 1
  }
  partial_rc=0
  payload_main "$tmpd2/answers" >"$tmpd2/out" 2>&1 || partial_rc=$?
  partial_out="$(cat "$tmpd2/out")"
  if ((partial_rc == 0)); then
    echo "partial should fail" >&2
    exit 1
  fi
  case "$partial_out" in
  *"pangolin service logs client"*) ;;
  *)
    echo "failed client should print a log hint: $partial_out" >&2
    exit 1
    ;;
  esac
  [[ "$site_called" == "1" && "$client_called" == "1" ]] ||
    { echo "both components tried" >&2; exit 1; }
  [[ "$newt_cleaned" == "1" ]] ||
    { echo "verified site should clean up legacy Newt" >&2; exit 1; }
  [[ "$client_args" == "cid csec https://p.example" ]] ||
    { echo "client answers not read" >&2; exit 1; }
  [[ "$stopped" == "pangolin-client" ]] ||
    { echo "failed client should be stopped" >&2; exit 1; }
); then
  exit 1
fi
grep -qx 'site' "$tmpd2/answers/verified" ||
  { echo "verified marker should record the site" >&2; exit 1; }
if grep -qx 'client' "$tmpd2/answers/verified"; then
  echo "failed client must not be recorded as verified" >&2
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd2"

# Hostile client credentials survive the answers file and reach the installer
# byte-for-byte.
tmpd6="$(mktemp -d)"
mkdir -p "$tmpd6/answers" "$tmpd6/root"
printf 'SITE=0\nCLIENT=1\nRECONFIGURE=0\nTARGET=host\n' >"$tmpd6/answers/flags"
hostile_client="s3cr\$et 'q' \"d\" \`id\` ; #hash
line2"
build_client_answers "$tmpd6/answers" "https://p.example" "$hostile_client" "$hostile_client"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd6/root"
if ! (
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  cleanup_legacy_addon() { :; }
  stop_service() { :; }
  install_client_systemd() {
    [[ "$1" == "$hostile_client" && "$2" == "$hostile_client" ]] || {
      echo "hostile client credentials changed" >&2
      exit 1
    }
    [[ "$3" == "https://p.example" ]] || {
      echo "client endpoint changed" >&2
      exit 1
    }
    mkdir -p "$PANGOLIN_ROOT/etc/pangolin"
    printf 'PANGOLIN_CLIENT_SECRET=x\n' >"$PANGOLIN_ROOT/etc/pangolin/pangolin-client.env"
    chmod 644 "$PANGOLIN_ROOT/etc/pangolin/pangolin-client.env"
  }
  payload_main "$tmpd6/answers" >/dev/null 2>&1 || exit 1
  [[ "$(stat -c '%a' "$PANGOLIN_ROOT/etc/pangolin/pangolin-client.env")" == "600" ]] ||
    { echo "client env must be private" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd6"

# Verification before cleanup: a site that never provisions is stopped and
# its legacy files stay in place.
tmpd3="$(mktemp -d)"
mkdir -p "$tmpd3/answers" "$tmpd3/root"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=1\nTARGET=host\n' >"$tmpd3/answers/flags"
write_private_file "$tmpd3/answers/site.json" \
  "$(site_config_provisioning https://p.example spk-1.key pve-1)"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd3/root"
if ! (
  installed=0
  cleaned=0
  newt_cleaned=0
  stopped=""
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { cleaned=1; }
  cleanup_legacy_newt() { newt_cleaned=1; }
  wait_for_provisioning() { return 1; }
  stop_service() { stopped="$2"; }
  install_site_systemd() { installed=1; }
  site_rc=0
  payload_main "$tmpd3/answers" >"$tmpd3/out" 2>&1 || site_rc=$?
  site_out="$(cat "$tmpd3/out")"
  if ((site_rc == 0)); then
    echo "unprovisioned site should fail" >&2
    exit 1
  fi
  case "$site_out" in
  *"pangolin service logs site"*) ;;
  *)
    echo "failed site should print a log hint: $site_out" >&2
    exit 1
    ;;
  esac
  [[ "$installed" == "1" && "$cleaned" == "0" && "$newt_cleaned" == "0" ]] ||
    { echo "cleanup must wait for verification" >&2; exit 1; }
  [[ "$stopped" == "pangolin-site" ]] ||
    { echo "failed site should be stopped" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd3"

# An existing verified site config is reused unless RECONFIGURE=1.
tmpd4="$(mktemp -d)"
mkdir -p "$tmpd4/answers" "$tmpd4/root/etc/pangolin"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=0\nTARGET=host\n' >"$tmpd4/answers/flags"
write_private_file "$tmpd4/root/etc/pangolin/site.json" \
  "$(site_config_static https://p.example old-id old-secret)"
chmod 644 "$tmpd4/root/etc/pangolin/site.json"
write_private_file "$tmpd4/answers/site.json" \
  "$(site_config_static https://p.example new-id new-secret)"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd4/root"
if ! (
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  wait_for_provisioning() { :; }
  stop_service() { :; }
  install_site_systemd() { :; }
  payload_main "$tmpd4/answers" >/dev/null 2>&1 ||
    { echo "reuse should succeed" >&2; exit 1; }
  grep -q '"id":"old-id"' "$tmpd4/root/etc/pangolin/site.json" ||
    { echo "existing site config must be reused" >&2; exit 1; }
  [[ "$(stat -c '%a' "$tmpd4/root/etc/pangolin/site.json")" == "600" ]] ||
    { echo "reused site config must be private" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=1\nTARGET=host\n' >"$tmpd4/answers/flags"
export PANGOLIN_ROOT="$tmpd4/root"
if ! (
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  wait_for_provisioning() { :; }
  stop_service() { :; }
  install_site_systemd() { :; }
  payload_main "$tmpd4/answers" >/dev/null 2>&1 ||
    { echo "reconfigure should succeed" >&2; exit 1; }
  grep -q '"id":"new-id"' "$tmpd4/root/etc/pangolin/site.json" ||
    { echo "reconfigure must replace the site config" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd4"

# New site answers replace a legacy site install. Migration must not make the
# old env file win over the credentials the operator supplied.
tmpd5="$(mktemp -d)"
mkdir -p "$tmpd5/answers" "$tmpd5/root/etc/pangolin"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=0\nTARGET=host\n' >"$tmpd5/answers/flags"
printf 'SITE_ID=old-id\nSITE_SECRET=old-secret\nPANGOLIN_ENDPOINT=https://p.example\n' \
  >"$tmpd5/root/etc/pangolin/pangolin-site.env"
write_private_file "$tmpd5/answers/site.json" \
  "$(site_config_static https://p.example new-id new-secret)"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd5/root"
if ! (
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  wait_for_provisioning() { :; }
  stop_service() { :; }
  install_site_systemd() { :; }
  payload_main "$tmpd5/answers" >/dev/null 2>&1 ||
    { echo "legacy replace should succeed" >&2; exit 1; }
  grep -q '"id":"new-id"' "$tmpd5/root/etc/pangolin/site.json" ||
    { echo "new answers must replace a legacy site config" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd5"

# A failed replacement restores the previous same-named unit and env files.
tmpd7="$(mktemp -d)"
mkdir -p "$tmpd7/answers" "$tmpd7/root/etc/systemd/system" "$tmpd7/root/etc/pangolin" \
  "$tmpd7/root/usr/local/bin"
printf 'OLD UNIT\n' >"$tmpd7/root/etc/systemd/system/pangolin-site.service"
printf 'OLD ENV\n' >"$tmpd7/root/etc/pangolin/pangolin-site.env"
printf 'OLD SITE CONFIG\n' >"$tmpd7/root/etc/pangolin/site.json"
cp "$tmpd7/root/etc/pangolin/site.json" "$tmpd7/original-site.json"
printf 'OLD WRAPPER\n' >"$tmpd7/root/usr/local/bin/pangolin-site-start"
cp "$tmpd7/root/usr/local/bin/pangolin-site-start" "$tmpd7/original-wrapper"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=1\nTARGET=host\n' >"$tmpd7/answers/flags"
write_private_file "$tmpd7/answers/site.json" \
  "$(site_config_static https://p.example new-id new-secret)"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd7/root"
if ! (
  stopped=""
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  cleanup_legacy_newt() { :; }
  wait_for_provisioning() { :; }
  stop_service() { stopped="$2"; }
  install_site_systemd() {
    printf 'NEW UNIT\n' >"$PANGOLIN_ROOT/etc/systemd/system/pangolin-site.service"
    printf 'NEW ENV\n' >"$PANGOLIN_ROOT/etc/pangolin/pangolin-site.env"
    printf 'NEW SITE CONFIG\n' >"$PANGOLIN_ROOT/etc/pangolin/site.json"
    printf 'NEW WRAPPER\n' >"$PANGOLIN_ROOT/usr/local/bin/pangolin-site-start"
    return 1
  }
  if payload_main "$tmpd7/answers" >/dev/null 2>&1; then
    echo "failed replacement should fail" >&2
    exit 1
  fi
  [[ "$stopped" == "pangolin-site" ]] ||
    { echo "failed site should be stopped" >&2; exit 1; }
  [[ -n "$SITE_INSTALL_BACKUP_DIR" ]] ||
    { echo "failed replacement should have a backup" >&2; exit 1; }
  grep -q 'OLD UNIT' "$SITE_INSTALL_BACKUP_DIR/pangolin-site.service" ||
    { echo "backup must hold the previous unit" >&2; exit 1; }
  grep -q 'OLD UNIT' "$PANGOLIN_ROOT/etc/systemd/system/pangolin-site.service" ||
    { echo "failed replacement must restore the previous unit" >&2; exit 1; }
  grep -q 'OLD ENV' "$PANGOLIN_ROOT/etc/pangolin/pangolin-site.env" ||
    { echo "failed replacement must restore the previous env" >&2; exit 1; }
  cmp -s "$tmpd7/original-site.json" "$PANGOLIN_ROOT/etc/pangolin/site.json" ||
    { echo "failed replacement must restore the previous site config bytes" >&2; exit 1; }
  cmp -s "$tmpd7/original-wrapper" "$PANGOLIN_ROOT/usr/local/bin/pangolin-site-start" ||
    { echo "failed replacement must restore the previous wrapper bytes" >&2; exit 1; }
  grep -q 'OLD WRAPPER' "$SITE_INSTALL_BACKUP_DIR/pangolin-site-start" ||
    { echo "wrapper backup must hold the previous bytes" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd7"

# A verified replacement keeps the new unit and does not restore the backup.
tmpd8="$(mktemp -d)"
mkdir -p "$tmpd8/answers" "$tmpd8/root/etc/systemd/system" "$tmpd8/root/etc/pangolin" \
  "$tmpd8/root/usr/local/bin"
printf 'OLD UNIT\n' >"$tmpd8/root/etc/systemd/system/pangolin-site.service"
printf 'OLD SITE CONFIG\n' >"$tmpd8/root/etc/pangolin/site.json"
printf 'OLD WRAPPER\n' >"$tmpd8/root/usr/local/bin/pangolin-site-start"
printf 'SITE=1\nCLIENT=0\nRECONFIGURE=1\nTARGET=host\n' >"$tmpd8/answers/flags"
write_private_file "$tmpd8/answers/site.json" \
  "$(site_config_static https://p.example new-id new-secret)"
old_pangolin_root="${PANGOLIN_ROOT:-}"
export PANGOLIN_ROOT="$tmpd8/root"
if ! (
  install_cli_binary() { :; }
  service_backend() { echo systemd; }
  migrate_existing_addon() { :; }
  migrate_legacy_newt() { :; }
  cleanup_legacy_addon() { :; }
  cleanup_legacy_newt() { :; }
  wait_for_provisioning() { :; }
  stop_service() { :; }
  install_site_systemd() {
    printf 'NEW UNIT\n' >"$PANGOLIN_ROOT/etc/systemd/system/pangolin-site.service"
    printf 'NEW WRAPPER\n' >"$PANGOLIN_ROOT/usr/local/bin/pangolin-site-start"
  }
  payload_main "$tmpd8/answers" >/dev/null 2>&1 ||
    { echo "verified replacement should succeed" >&2; exit 1; }
  [[ -f "$SITE_INSTALL_BACKUP_DIR/pangolin-site.service" ]] ||
    { echo "success should still keep a pre-install backup" >&2; exit 1; }
  grep -q 'OLD UNIT' "$SITE_INSTALL_BACKUP_DIR/pangolin-site.service" ||
    { echo "backup must hold the previous unit" >&2; exit 1; }
  grep -q 'NEW UNIT' "$PANGOLIN_ROOT/etc/systemd/system/pangolin-site.service" ||
    { echo "success must keep the new unit" >&2; exit 1; }
  if grep -q 'OLD UNIT' "$PANGOLIN_ROOT/etc/systemd/system/pangolin-site.service"; then
    echo "success must not restore the backup" >&2
    exit 1
  fi
  grep -q '"id":"new-id"' "$PANGOLIN_ROOT/etc/pangolin/site.json" ||
    { echo "success must keep the new site config" >&2; exit 1; }
  if grep -q 'OLD SITE CONFIG' "$PANGOLIN_ROOT/etc/pangolin/site.json"; then
    echo "success must not restore the old site config" >&2
    exit 1
  fi
  grep -q 'OLD SITE CONFIG' "$SITE_INSTALL_BACKUP_DIR/site.json" ||
    { echo "site config backup must hold the previous bytes" >&2; exit 1; }
  grep -q 'NEW WRAPPER' "$PANGOLIN_ROOT/usr/local/bin/pangolin-site-start" ||
    { echo "success must keep the new wrapper" >&2; exit 1; }
  grep -q 'OLD WRAPPER' "$SITE_INSTALL_BACKUP_DIR/pangolin-site-start" ||
    { echo "wrapper backup must hold the previous bytes" >&2; exit 1; }
); then
  exit 1
fi
export PANGOLIN_ROOT="$old_pangolin_root"
rm -rf "$tmpd8"

# Dry run validates and prints the plan with no network, prompt, secret, or
# filesystem change.
dry="$(mktemp -d)"
mkdir -p "$dry/bin" "$dry/tmp"
cat >"$dry/bin/curl" <<EOF
#!/usr/bin/env bash
printf ran >>"$dry/curl-ran"
exit 1
EOF
chmod 755 "$dry/bin/curl"
if ! dry_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=sec bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "dry run failed: $dry_out" >&2
  exit 1
fi
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "dry run wrote files" >&2; exit 1; }
[[ ! -e "$dry/curl-ran" ]] || { echo "dry run used the network" >&2; exit 1; }
case "$dry_out" in
*Target:*host*) ;;
*) echo "dry run target missing" >&2; exit 1 ;;
esac
case "$dry_out" in
*Mode:*site*) ;;
*) echo "dry run mode missing" >&2; exit 1 ;;
esac
case "$dry_out" in
*sec*) echo "dry run printed the secret" >&2; exit 1 ;;
esac
case "$dry_out" in
*"Validate the target OS floor"*) ;;
*) echo "dry run OS plan missing" >&2; exit 1 ;;
esac
case "$dry_out" in
*"/dev/net/tun"*)
  echo "plain site dry run must not mention TUN" >&2
  exit 1
  ;;
esac

if ! dry_client_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=client var_target=host var_pangolin_endpoint=https://p.example \
    var_client_id=cid var_client_secret=csecret bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "client dry run failed: $dry_client_out" >&2
  exit 1
fi
case "$dry_client_out" in
*"Ensure /dev/net/tun exists on the host"*) ;;
*) echo "dry run host TUN plan missing" >&2; exit 1 ;;
esac
case "$dry_client_out" in
*csecret*) echo "dry run printed the client secret" >&2; exit 1 ;;
esac

if ! dry_prov_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_provisioning_key=spk-SECRET var_reconfigure=1 \
    bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "provisioning dry run failed: $dry_prov_out" >&2
  exit 1
fi
case "$dry_prov_out" in
*tier3*"approve new sites"*"second server-side site"*) ;;
*) echo "dry run provisioning notes missing" >&2; exit 1 ;;
esac
case "$dry_prov_out" in
*spk-SECRET*) echo "dry run printed the provisioning key" >&2; exit 1 ;;
esac

# Native site mode lists the toggles and interface names and needs TUN, without
# printing credentials.
if ! dry_native_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=s3cr3t-DO-NOT-PRINT \
    var_site_native=1 var_site_native_main=1 bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "native dry run failed: $dry_native_out" >&2
  exit 1
fi
for token in "native client tunnels" "native main tunnel" "interface pangolin" \
  "interface pangolin-main" "/dev/net/tun"; do
  case "$dry_native_out" in
  *"$token"*) ;;
  *)
    echo "native dry run missing [$token]: $dry_native_out" >&2
    exit 1
    ;;
  esac
done
case "$dry_native_out" in
*s3cr3t-DO-NOT-PRINT*) echo "native dry run printed the secret" >&2; exit 1 ;;
esac
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "native dry run wrote files" >&2; exit 1; }

# With no new site form, reuse is only possible when the existing config matches;
# the dry run says so instead of printing an unconditional success plan.
if ! dry_reuse_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_native=1 bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "native reuse dry run failed: $dry_reuse_out" >&2
  exit 1
fi
case "$dry_reuse_out" in
*"native interface settings are applied only on create or reconfigure"*var_reconfigure=1*) ;;
*)
  echo "native reuse dry run note missing: $dry_reuse_out" >&2
  exit 1
  ;;
esac
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "native reuse dry run wrote files" >&2; exit 1; }
[[ ! -e "$dry/curl-ran" ]] || { echo "native reuse dry run used the network" >&2; exit 1; }

# Invalid native values fail before any side effect, including a dry run.
bad_flag_rc=0
bad_flag_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=secret var_site_native=yes \
    bash "$ROOT/add-pangolin.sh" 2>&1
)" || bad_flag_rc=$?
[[ "$bad_flag_rc" -ne 0 ]] || { echo "invalid native flag should fail" >&2; exit 1; }
case "$bad_flag_out" in
*"Invalid native flag: yes"*) ;;
*) echo "native flag validation message: $bad_flag_out" >&2; exit 1 ;;
esac

bad_name_rc=0
bad_name_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=secret var_site_native=1 \
    var_site_interface="bad name" bash "$ROOT/add-pangolin.sh" 2>&1
)" || bad_name_rc=$?
[[ "$bad_name_rc" -ne 0 ]] || { echo "invalid native interface should fail" >&2; exit 1; }
case "$bad_name_out" in
*"Invalid native interface name: bad name"*) ;;
*) echo "interface validation message: $bad_name_out" >&2; exit 1 ;;
esac
[[ ! -e "$dry/curl-ran" ]] || { echo "native dry runs used the network" >&2; exit 1; }
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "native dry runs wrote files" >&2; exit 1; }
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "dry runs wrote files" >&2; exit 1; }
[[ ! -e "$dry/curl-ran" ]] || { echo "dry runs used the network" >&2; exit 1; }

# The documented `bash -c "$(curl ...)"` form and a stdin run must reach main
# under set -u even though BASH_SOURCE[0] is unset.
if ! bashc_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=sec bash -c "$(cat "$ROOT/add-pangolin.sh")" 2>&1
)"; then
  echo "bash -c dry run failed: $bashc_out" >&2
  exit 1
fi
case "$bashc_out" in
*"Pangolin addon dry run"*"Target: host"*) ;;
*) echo "bash -c dry run did not reach main: $bashc_out" >&2; exit 1 ;;
esac
case "$bashc_out" in
*sec*) echo "bash -c dry run printed the secret" >&2; exit 1 ;;
esac
if ! stdin_out="$(
  TMPDIR="$dry/tmp" PATH="$dry/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=client var_target=host var_pangolin_endpoint=https://p.example \
    var_client_id=cid var_client_secret=csecret bash <"$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "stdin dry run failed: $stdin_out" >&2
  exit 1
fi
case "$stdin_out" in
*"Pangolin addon dry run"*"Target: host"*) ;;
*) echo "stdin dry run did not reach main: $stdin_out" >&2; exit 1 ;;
esac
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "guard dry runs wrote files" >&2; exit 1; }
[[ ! -e "$dry/curl-ran" ]] || { echo "guard dry runs used the network" >&2; exit 1; }
rm -rf "$dry"

# Dry run never opens whiptail: missing selectors fail with a required-values
# list, and an invalid var_reconfigure is rejected.
dry2="$(mktemp -d)"
mkdir -p "$dry2/bin"
cat >"$dry2/bin/whiptail" <<EOF
#!/usr/bin/env bash
printf called >>"$dry2/whiptail-ran"
exit 1
EOF
chmod 755 "$dry2/bin/whiptail"
missing_rc=0
missing_out="$(
  PATH="$dry2/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_pangolin_endpoint=https://p.example var_site_id=id var_site_secret=sec \
    bash "$ROOT/add-pangolin.sh" 2>&1
)" || missing_rc=$?
[[ "$missing_rc" -ne 0 ]] || { echo "dry run without selectors should fail" >&2; exit 1; }
case "$missing_out" in
*"Missing required values:"*var_mode*var_target*) ;;
*) echo "dry run missing-values message: $missing_out" >&2; exit 1 ;;
esac
[[ ! -e "$dry2/whiptail-ran" ]] || { echo "dry run opened whiptail" >&2; exit 1; }

target_rc=0
target_out="$(
  PATH="$dry2/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 var_mode=site \
    var_pangolin_endpoint=https://p.example var_site_id=id var_site_secret=sec \
    bash "$ROOT/add-pangolin.sh" 2>&1
)" || target_rc=$?
[[ "$target_rc" -ne 0 ]] || { echo "dry run without var_target should fail" >&2; exit 1; }
case "$target_out" in
*"Missing required values:"*var_target*) ;;
*) echo "dry run missing-target message: $target_out" >&2; exit 1 ;;
esac
[[ ! -e "$dry2/whiptail-ran" ]] || { echo "dry run opened whiptail" >&2; exit 1; }

reconfigure_rc=0
reconfigure_out="$(
  PATH="$dry2/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_target=host var_reconfigure=yes \
    var_pangolin_endpoint=https://p.example var_site_id=id var_site_secret=sec \
    bash "$ROOT/add-pangolin.sh" 2>&1
)" || reconfigure_rc=$?
[[ "$reconfigure_rc" -ne 0 ]] || { echo "invalid var_reconfigure should fail" >&2; exit 1; }
case "$reconfigure_out" in
*"Invalid var_reconfigure: yes"*) ;;
*) echo "reconfigure validation message: $reconfigure_out" >&2; exit 1 ;;
esac
[[ ! -e "$dry2/whiptail-ran" ]] || { echo "dry run opened whiptail" >&2; exit 1; }

# An unknown PANGOLIN_DRY_RUN value must fail before any side effect instead of
# silently performing a live install.
dryrun_rc=0
dryrun_out="$(
  PATH="$dry2/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=yes \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=sec bash "$ROOT/add-pangolin.sh" 2>&1
)" || dryrun_rc=$?
[[ "$dryrun_rc" -ne 0 ]] || { echo "invalid PANGOLIN_DRY_RUN should fail" >&2; exit 1; }
case "$dryrun_out" in
*"Invalid PANGOLIN_DRY_RUN: yes"*) ;;
*) echo "dry-run validation message: $dryrun_out" >&2; exit 1 ;;
esac
[[ ! -e "$dry2/whiptail-ran" ]] || { echo "invalid dry run opened whiptail" >&2; exit 1; }

# `true` is the common spelling and is accepted as a dry run, never a live run.
if ! true_out="$(
  PATH="$dry2/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=true \
    var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
    var_site_id=id var_site_secret=sec bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "PANGOLIN_DRY_RUN=true should be a dry run: $true_out" >&2
  exit 1
fi
case "$true_out" in
*"Pangolin addon dry run"*) ;;
*) echo "PANGOLIN_DRY_RUN=true did not run a dry run: $true_out" >&2; exit 1 ;;
esac
rm -rf "$dry2"

# Multi-target selection: comma and space lists, normalization, duplicates, and
# invalid values. `var_target` stays valid for one target; `var_targets` wins
# when both are set.
assert_eq $'host\n101\n102' "$(_parse_targets 'host,101, 102')"
assert_eq $'host\n101' "$(_parse_targets 'host   101')"
assert_eq "101" "$(_parse_targets '0101')"
assert_eq $'101\n102' "$(var_targets='101,102' _resolve_targets)"
assert_eq "host" "$(var_target='host' _resolve_targets)"
assert_eq "host" "$(var_targets='host' var_target='101' _resolve_targets)"
for bad in 'abc' '0' '-1' 'host;101' '101,abc'; do
  if _parse_targets "$bad" >/dev/null 2>&1; then
    echo "target [$bad] should fail" >&2
    exit 1
  fi
done
for dup in '101,101' 'host host' '101,0101'; do
  dup_out="$(_parse_targets "$dup" 2>&1)" && {
    echo "duplicate [$dup] should fail" >&2
    exit 1
  }
  case "$dup_out" in
  *Duplicate*) ;;
  *)
    echo "duplicate message for [$dup]: $dup_out" >&2
    exit 1
    ;;
  esac
done

# Per-target credential lookup: a suffixed variable wins, and the global
# fallback exists only when exactly one target is selected.
assert_eq "cid-101" "$(var_client_id_101=cid-101 _target_value var_client_id 101 2)"
assert_eq "" "$(var_client_id=global _target_value var_client_id 101 2)"
assert_eq "global" "$(var_client_id=global _target_value var_client_id 101 1)"
assert_eq "cid-101" "$(var_client_id_101=cid-101 var_client_id=global \
  _target_value var_client_id 101 1)"
assert_eq "spk-101" "$(var_site_provisioning_key_101=spk-101 \
  _target_value var_site_provisioning_key 101 2)"
assert_eq "host-secret" "$(var_site_secret_host=host-secret \
  _target_value var_site_secret host 3)"
if ! (
  var_client_id=global-id var_client_secret=global-secret
  var_client_id_101=per-id var_client_secret_101=per-secret
  _load_target_credentials 101 2
  [[ "$var_client_id" == per-id && "$var_client_secret" == per-secret ]] || exit 1
  _load_target_credentials 102 2
  [[ -z "$var_client_id" && -z "$var_client_secret" ]] || exit 1
); then
  echo "per-target credential lookup failed" >&2
  exit 1
fi
if ! (
  var_client_id=global-id var_client_secret=global-secret
  _load_target_credentials 101 1
  [[ "$var_client_id" == global-id && "$var_client_secret" == global-secret ]] || exit 1
); then
  echo "single-target global fallback failed" >&2
  exit 1
fi
if ! (
  var_site_id=global-id var_site_secret=global-secret
  var_site_id_101=per-id var_site_secret_101=per-secret
  _reset_target_credentials
  [[ -z "$var_site_id" && -z "$var_site_secret" ]] || exit 1
  # The endpoint and native toggles are shared and must survive the reset.
  var_pangolin_endpoint=https://p.example
  var_site_native=1
  _reset_target_credentials
  [[ "$var_pangolin_endpoint" == https://p.example && "$var_site_native" == 1 ]] || exit 1
); then
  echo "credential reset removed shared selections" >&2
  exit 1
fi

# Multi-target install loop. A fake payload records each invocation and fails
# only for the CTIDs listed in fail-targets. The fake pct maps the remote
# answers path onto a local directory and records tag changes.
loop="$(mktemp -d)"
mkdir -p "$loop/bin" "$loop/tmp" "$loop/remote"
cat >"$loop/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$FAKE_LOG"
ctid="$2"
case "$1" in
config) printf 'tags: old;pangolin-cli\n' ;;
list) printf 'VMID Status Lock Name\n101 running c1\n102 stopped c2\n' ;;
set) exit 0 ;;
status) printf 'status: running\n' ;;
start | shutdown) exit 0 ;;
push)
  src="$3"
  dst="${4#/root/.pangolin-addon/}"
  mkdir -p "$FAKE_REMOTE_DIR/$ctid"
  cp "$src" "$FAKE_REMOTE_DIR/$ctid/$dst"
  ;;
exec)
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  dir="$FAKE_REMOTE_DIR/$ctid"
  case "$*" in
  *"rm -rf /root/.pangolin-addon"*) rm -rf "$dir" ;;
  *"cat /root/.pangolin-addon/verified"*) cat "$dir/verified" 2>/dev/null ;;
  *"mkdir -p /root/.pangolin-addon"*) mkdir -p "$dir" ;;
  *"chmod "*) : ;;
  *"payload.sh"*) bash "$dir/payload.sh" "$dir" ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$loop/bin/pct"
cat >"$loop/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_WHIPTAIL_LOG"
case "$*" in
*"Targets (space selects"*) printf '%s' "${FAKE_TARGETS_OUT:-}" >&2 ;;
*"Site networking:"*)
  if [[ "${FAKE_NATIVE_CANCEL:-0}" == 1 ]]; then exit 1; fi
  printf '%s' "${FAKE_NATIVE_OUT:-}" >&2
  ;;
*"Site credentials:"*) printf 'static' >&2 ;;
*"Existing site"*) printf 'replace' >&2 ;;
*"Select components"*) printf 'client' >&2 ;;
*"Pangolin endpoint"*) printf '%s' "${FAKE_ENDPOINT_OUT:-https://p.example}" >&2 ;;
*"Site ID"*) printf 'id' >&2 ;;
*"Site secret"*) printf 'sec' >&2 ;;
*"Site name"*) printf 'pve' >&2 ;;
*"Machine client ID"*) printf 'cid' >&2 ;;
*"Machine client secret"*) printf 'csec' >&2 ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$loop/bin/whiptail"
cat >"$loop/payload.sh" <<EOF
#!/usr/bin/env bash
# Sourced by main, executed per target.
if [[ "\${BASH_SOURCE[0]:-}" != "\$0" ]]; then
  return 0
fi
answers="\${1:-}"
target="\$(sed -n 's/^TARGET=//p' "\$answers/flags" 2>/dev/null)"
printf '%s\n' "\$target" >>"$loop/ran"
if grep -qx "\$target" "$loop/fail-targets" 2>/dev/null; then
  exit 1
fi
if grep -qx "\$target" "$loop/partial-targets" 2>/dev/null; then
  printf 'site\n' >"\$answers/verified"
  exit 1
fi
printf 'client\n' >"\$answers/verified"
EOF
: >"$loop/fail-targets"

# Interactive target checklist: rows come from pct list, a selection parses to
# CTIDs, and an empty selection fails.
: >"$loop/wlog"
targets_out="$(
  unset var_mode var_unattended var_targets var_target
  export PATH="$loop/bin:$PATH" FAKE_WHIPTAIL_LOG="$loop/wlog"
  export FAKE_TARGETS_OUT='"host" "101"'
  _resolve_targets
)" || { echo "interactive checklist selection failed" >&2; exit 1; }
assert_eq $'host\n101' "$targets_out"
grep -q 'This Proxmox host' "$loop/wlog" ||
  { echo "checklist host row missing" >&2; exit 1; }
grep -q 'LXC c1 (CTID 101)' "$loop/wlog" ||
  { echo "checklist LXC row missing" >&2; exit 1; }
empty_rc=0
empty_out="$(
  unset var_mode var_unattended var_targets var_target
  export PATH="$loop/bin:$PATH" FAKE_WHIPTAIL_LOG="$loop/wlog"
  export FAKE_TARGETS_OUT=''
  _resolve_targets 2>&1
)" || empty_rc=$?
[[ "$empty_rc" -ne 0 ]] || { echo "empty checklist must fail" >&2; exit 1; }
case "$empty_out" in
*"Select at least one target"*) ;;
*) echo "empty checklist message: $empty_out" >&2; exit 1 ;;
esac

# Interactive shared selections: the endpoint is asked once and the native
# checklist is asked once, then reused for the next target. Credentials are
# cleared between targets.
: >"$loop/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target
  unset var_pangolin_endpoint var_site_id var_site_secret
  unset var_site_provisioning_key var_site_name var_site_native var_site_native_main
  export PATH="$loop/bin:$PATH" FAKE_WHIPTAIL_LOG="$loop/wlog"
  export FAKE_NATIVE_OUT='"client"'
  NATIVE_PROMPTED=0
  _target_site_verified() { return 1; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0
  [[ "$var_pangolin_endpoint" == https://p.example ]] || exit 1
  [[ "$var_site_id" == id && "$var_site_secret" == sec ]] || exit 1
  [[ "$var_site_native" == 1 ]] || exit 1
  _reset_target_credentials
  [[ -z "$var_site_id" && -z "$var_site_secret" ]] || exit 1
  export FAKE_NATIVE_OUT=''
  _prompt_inputs 101 1 0
  [[ "$var_pangolin_endpoint" == https://p.example ]] || exit 1
  [[ "$var_site_native" == 1 ]] || exit 1
  [[ "$(grep -c 'Pangolin endpoint' "$FAKE_WHIPTAIL_LOG")" == 1 ]] || exit 1
  [[ "$(grep -c 'Site networking:' "$FAKE_WHIPTAIL_LOG")" == 1 ]] || exit 1
) >"$loop/prompt-out" 2>&1; then
  echo "interactive shared selections regression:" >&2
  cat "$loop/prompt-out" >&2
  exit 1
fi

# A cancelled native checklist is not recorded as asked, so the next target is
# prompted again instead of silently inheriting default toggles.
: >"$loop/wlog2"
if ! (
  unset var_mode var_unattended var_targets var_target
  unset var_pangolin_endpoint var_site_id var_site_secret
  unset var_site_provisioning_key var_site_name var_site_native var_site_native_main
  export PATH="$loop/bin:$PATH" FAKE_WHIPTAIL_LOG="$loop/wlog2"
  export FAKE_NATIVE_OUT='"client"'
  NATIVE_PROMPTED=0
  _target_site_verified() { return 1; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  export FAKE_NATIVE_CANCEL=1
  cancel_rc=0
  _prompt_inputs host 1 0 >/dev/null 2>&1 || cancel_rc=$?
  [[ "$cancel_rc" -ne 0 ]] || exit 1
  [[ "$NATIVE_PROMPTED" == 0 ]] || exit 1
  _reset_target_credentials
  export FAKE_NATIVE_CANCEL=0
  _prompt_inputs 101 1 0
  [[ "$var_site_native" == 1 ]] || exit 1
  [[ "$(grep -c 'Site networking:' "$FAKE_WHIPTAIL_LOG")" == 2 ]] || exit 1
) >"$loop/cancel-out" 2>&1; then
  echo "cancelled native checklist regression:" >&2
  cat "$loop/cancel-out" >&2
  exit 1
fi

# Run main with every host-touching step stubbed except the payload and tags.
_run_loop() {
  (
    export PATH="$loop/bin:$PATH"
    export FAKE_LOG="$loop/log" FAKE_REMOTE_DIR="$loop/remote"
    export FAKE_PAYLOAD="$loop/payload.sh" TMPDIR="$loop/tmp"
    export FAKE_WHIPTAIL_LOG="$loop/wlog"
    _ensure_curl() { :; }
    _load_core() { if [[ "${FAKE_LOAD_CORE_TRACE:-0}" == 1 ]]; then set -x; fi; }
    require_pve_host() { return 0; }
    header_info() { :; }
    msg_info() { printf 'INFO:%s\n' "$*"; }
    msg_ok() { printf 'OK:%s\n' "$*"; }
    msg_warn() { printf 'WARN:%s\n' "$*" >&2; }
    msg_error() { printf 'ERROR:%s\n' "$*" >&2; }
    _ensure_lxc_running() { ! grep -qx "$1" "$loop/fail-start" 2>/dev/null; }
    _validate_target_os() { ! grep -qx "$1" "$loop/fail-os" 2>/dev/null; }
    _apply_lxc_tun() { ! grep -qx "$1" "$loop/fail-tun" 2>/dev/null; }
    _ensure_lxc_runtime() { :; }
    _ensure_host_tun() { :; }
    fetch_payload() { install -m 0600 "$FAKE_PAYLOAD" "$1"; }
    main
  )
}

# All targets succeed: the payload runs once per target, every target is
# summarized as ok, only the LXC is tagged, and every answers copy is removed.
: >"$loop/ran"
: >"$loop/log"
if ! all_out="$(
  var_mode=client var_targets="host,101" var_pangolin_endpoint=https://p.example \
    var_client_id_host=id-host var_client_secret_host=sec-host \
    var_client_id_101=id-101 var_client_secret_101=sec-101 _run_loop 2>&1
)"; then
  echo "multi-target all-success run failed: $all_out" >&2
  exit 1
fi
assert_eq $'host\n101' "$(cat "$loop/ran")"
case "$all_out" in
*"host: ok (client)"*) ;;
*) echo "all-success summary missing host: $all_out" >&2; exit 1 ;;
esac
case "$all_out" in
*"101: ok (client)"*) ;;
*) echo "all-success summary missing 101: $all_out" >&2; exit 1 ;;
esac
grep -q 'pct set 101 -tags old;pangolin-client' "$loop/log" ||
  { echo "successful LXC must be tagged" >&2; exit 1; }
grep -q 'pct exec 101 -- env' "$loop/log" ||
  { echo "LXC payload must run through pct exec" >&2; exit 1; }
if grep -q 'PANGOLIN_CLIENT_SECRET=' "$loop/log"; then
  echo "secret reached pct argv" >&2
  exit 1
fi
if grep -q 'sec-101\|sec-host' "$loop/log"; then
  echo "secret reached the pct log" >&2
  exit 1
fi
[[ -z "$(ls -A "$loop/remote")" ]] || { echo "remote answers not cleaned" >&2; exit 1; }
[[ -z "$(ls -A "$loop/tmp")" ]] || { echo "local answers not cleaned" >&2; exit 1; }

# Partial failure: the middle target fails, the last target still runs and the
# run exits non-zero. Only the successful LXC is tagged.
printf '101\n' >"$loop/fail-targets"
: >"$loop/ran"
: >"$loop/log"
partial_loop_rc=0
partial_loop_out="$(
  var_mode=client var_targets="host 101 102" var_pangolin_endpoint=https://p.example \
    var_client_id_host=id-host var_client_secret_host=sec-host \
    var_client_id_101=id-101 var_client_secret_101=sec-101 \
    var_client_id_102=id-102 var_client_secret_102=sec-102 _run_loop 2>&1
)" || partial_loop_rc=$?
[[ "$partial_loop_rc" -ne 0 ]] || { echo "partial failure must exit non-zero" >&2; exit 1; }
assert_eq $'host\n101\n102' "$(cat "$loop/ran")"
case "$partial_loop_out" in
*"101: failed"*) ;;
*) echo "partial summary missing the failure: $partial_loop_out" >&2; exit 1 ;;
esac
case "$partial_loop_out" in
*"102: ok (client)"*) ;;
*) echo "partial run must continue after the failure: $partial_loop_out" >&2; exit 1 ;;
esac
case "$partial_loop_out" in
*"continuing with the remaining targets"*) ;;
*) echo "continuation message missing: $partial_loop_out" >&2; exit 1 ;;
esac
if grep -q 'pct set 101 -tags' "$loop/log"; then
  echo "failed target must not be tagged" >&2
  exit 1
fi
grep -q 'pct set 102 -tags' "$loop/log" ||
  { echo "second successful target must be tagged" >&2; exit 1; }
[[ -z "$(ls -A "$loop/tmp")" ]] || { echo "partial run left local answers" >&2; exit 1; }
[[ -z "$(ls -A "$loop/remote")" ]] || { echo "partial run left remote answers" >&2; exit 1; }

# All targets fail: every payload is attempted and the run exits non-zero.
printf 'host\n101\n102\n' >"$loop/fail-targets"
: >"$loop/ran"
: >"$loop/log"
all_fail_rc=0
all_fail_out="$(
  var_mode=client var_targets="host 101 102" var_pangolin_endpoint=https://p.example \
    var_client_id_host=id-host var_client_secret_host=sec-host \
    var_client_id_101=id-101 var_client_secret_101=sec-101 \
    var_client_id_102=id-102 var_client_secret_102=sec-102 _run_loop 2>&1
)" || all_fail_rc=$?
[[ "$all_fail_rc" -ne 0 ]] || { echo "all-failure run must exit non-zero" >&2; exit 1; }
assert_eq $'host\n101\n102' "$(cat "$loop/ran")"
for t in host 101 102; do
  case "$all_fail_out" in
  *"$t: failed"*) ;;
  *) echo "all-failure summary missing $t: $all_fail_out" >&2; exit 1 ;;
  esac
done
if grep -q 'pct set' "$loop/log"; then
  echo "failed targets must not be tagged" >&2
  exit 1
fi

# Single-target compatibility: `var_target` plus unsuffixed credentials still
# installs one host target.
: >"$loop/fail-targets"
: >"$loop/ran"
: >"$loop/log"
if ! single_out="$(
  var_mode=client var_target=host var_pangolin_endpoint=https://p.example \
    var_client_id=id-global var_client_secret=sec-global _run_loop 2>&1
)"; then
  echo "single var_target run failed: $single_out" >&2
  exit 1
fi
assert_eq "host" "$(cat "$loop/ran")"
case "$single_out" in
*"host: ok (client)"*) ;;
*) echo "single-target summary missing: $single_out" >&2; exit 1 ;;
esac

# The first interactive target keeps environment-provided credentials; only
# later targets are reset. A client target with all values supplied must not
# prompt for credentials.
: >"$loop/fail-targets"
: >"$loop/ran"
: >"$loop/log"
: >"$loop/wlog"
if ! interactive_out="$(
  var_mode= var_target=host var_pangolin_endpoint=https://p.example \
    var_client_id=env-id var_client_secret=env-secret _run_loop 2>&1
)"; then
  echo "interactive single target failed: $interactive_out" >&2
  exit 1
fi
assert_eq "host" "$(cat "$loop/ran")"
[[ "$(wc -l <"$loop/wlog")" == 1 ]] || {
  echo "first target must not prompt for supplied credentials:" >&2
  cat "$loop/wlog" >&2
  exit 1
}

# `_load_core` can re-enable xtrace through the core dev-mode helpers. The
# install path must disable it again before credential activation.
: >"$loop/fail-targets"
: >"$loop/ran"
: >"$loop/log"
trace_install_rc=0
trace_install_out="$(
  FAKE_LOAD_CORE_TRACE=1 var_mode=client var_targets="host,101" \
    var_pangolin_endpoint=https://p.example \
    var_client_id_host=TRACE-ID-HOST var_client_secret_host=TRACE-SECRET-HOST \
    var_client_id_101=TRACE-ID-101 var_client_secret_101=TRACE-SECRET-101 \
    _run_loop 2>&1
)" || trace_install_rc=$?
[[ "$trace_install_rc" -eq 0 ]] ||
  { echo "install path failed after a traced core load" >&2; exit 1; }
assert_eq $'host\n101' "$(cat "$loop/ran")"
case "$trace_install_out" in
*TRACE-SECRET* | *TRACE-ID-*)
  echo "a traced core load leaked a credential" >&2
  exit 1
  ;;
esac

# Failure before the payload: an LXC that cannot start, an unsupported OS, and
# a failed TUN step each fail that target without running the payload or
# tagging it, and the later targets still install.
printf '101\n' >"$loop/fail-start"
printf '102\n' >"$loop/fail-os"
printf '103\n' >"$loop/fail-tun"
: >"$loop/ran"
: >"$loop/log"
pre_rc=0
pre_out="$(
  var_mode=client var_targets="host 101 102 103" var_pangolin_endpoint=https://p.example \
    var_client_id_host=id-host var_client_secret_host=sec-host \
    var_client_id_101=id-101 var_client_secret_101=sec-101 \
    var_client_id_102=id-102 var_client_secret_102=sec-102 \
    var_client_id_103=id-103 var_client_secret_103=sec-103 _run_loop 2>&1
)" || pre_rc=$?
[[ "$pre_rc" -ne 0 ]] || { echo "pre-payload failures must exit non-zero" >&2; exit 1; }
assert_eq "host" "$(cat "$loop/ran")"
for t in 101 102 103; do
  case "$pre_out" in
  *"$t: failed"*) ;;
  *) echo "pre-payload failure missing $t: $pre_out" >&2; exit 1 ;;
  esac
done
if grep -q 'pct set' "$loop/log"; then
  echo "pre-payload failures must not be tagged" >&2
  exit 1
fi
[[ -z "$(ls -A "$loop/tmp")" ]] || { echo "pre-payload run left local answers" >&2; exit 1; }
[[ -z "$(ls -A "$loop/remote")" ]] || { echo "pre-payload run left remote answers" >&2; exit 1; }
rm -f "$loop/fail-start" "$loop/fail-os" "$loop/fail-tun"

# A failed payload can leave a partial verified marker. It must not be tagged.
printf '101\n' >"$loop/partial-targets"
: >"$loop/ran"
: >"$loop/log"
partial_marker_rc=0
partial_marker_out="$(
  var_mode=client var_targets="host 101 102" var_pangolin_endpoint=https://p.example \
    var_client_id_host=id-host var_client_secret_host=sec-host \
    var_client_id_101=id-101 var_client_secret_101=sec-101 \
    var_client_id_102=id-102 var_client_secret_102=sec-102 _run_loop 2>&1
)" || partial_marker_rc=$?
[[ "$partial_marker_rc" -ne 0 ]] || { echo "partial marker run must exit non-zero" >&2; exit 1; }
assert_eq $'host\n101\n102' "$(cat "$loop/ran")"
case "$partial_marker_out" in
*"101: failed"*) ;;
*) echo "partial marker target must fail: $partial_marker_out" >&2; exit 1 ;;
esac
if grep -q 'pct set 101' "$loop/log"; then
  echo "a partial verified marker must not tag the failed target" >&2
  exit 1
fi
grep -q 'pct set 102 -tags' "$loop/log" ||
  { echo "the next target must still be tagged" >&2; exit 1; }
: >"$loop/partial-targets"

# Multi-target dry run lists every target and never touches the network.
: >"$loop/log"
if ! loop_dry_out="$(
  TMPDIR="$loop/tmp" PATH="$loop/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=site var_targets="host,101" var_pangolin_endpoint=https://p.example \
    var_site_id_host=id-host var_site_secret_host=sec-host \
    var_site_id_101=id-101 var_site_secret_101=sec-101 \
    bash "$ROOT/add-pangolin.sh" 2>&1
)"; then
  echo "multi-target dry run failed: $loop_dry_out" >&2
  exit 1
fi
assert_eq "2" "$(printf '%s\n' "$loop_dry_out" | grep -c '^Target: ')"
case "$loop_dry_out" in
*"Target: host"*"Target: LXC CTID 101"*) ;;
*) echo "dry run must list every target: $loop_dry_out" >&2; exit 1 ;;
esac
case "$loop_dry_out" in
*"Selected targets: 2"*) ;;
*) echo "dry run target count missing: $loop_dry_out" >&2; exit 1 ;;
esac
case "$loop_dry_out" in
*sec-host* | *sec-101*) echo "dry run printed a secret" >&2; exit 1 ;;
esac
[[ -z "$(ls -A "$loop/tmp")" ]] || { echo "dry run wrote files" >&2; exit 1; }
[[ ! -s "$loop/log" ]] || { echo "dry run used pct" >&2; exit 1; }

# A multi-target dry run must not fall back to the global credentials.
global_dry_rc=0
global_dry_out="$(
  TMPDIR="$loop/tmp" PATH="$loop/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=client var_targets="host,101" var_pangolin_endpoint=https://p.example \
    var_client_id=id-global var_client_secret=sec-global \
    bash "$ROOT/add-pangolin.sh" 2>&1
)" || global_dry_rc=$?
[[ "$global_dry_rc" -ne 0 ]] || { echo "global creds must not cover two targets" >&2; exit 1; }
case "$global_dry_out" in
*"Missing required values:"*var_client_id*) ;;
*) echo "multi-target global fallback message: $global_dry_out" >&2; exit 1 ;;
esac

# An inherited bash -x must not print credentials. The dry run exits before the
# install path, so it is the strictest xtrace regression case.
xtrace_rc=0
xtrace_err="$(
  TMPDIR="$loop/tmp" PATH="$loop/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
    var_mode=client var_targets="host,101" var_pangolin_endpoint=https://p.example \
    var_client_id_host=XT-ID-HOST var_client_secret_host=XT-SECRET-HOST \
    var_client_id_101=XT-ID-101 var_client_secret_101=XT-SECRET-101 \
    bash -x "$ROOT/add-pangolin.sh" 2>&1 >/dev/null
)" || xtrace_rc=$?
[[ "$xtrace_rc" -eq 0 ]] || { echo "bash -x dry run failed" >&2; exit 1; }
case "$xtrace_err" in
*XT-SECRET* | *XT-ID-*)
  echo "xtrace printed a credential" >&2
  exit 1
  ;;
esac

rm -rf "$loop"

# A partial result advertises next steps only for the component that verified.
partial_steps="$(
  msg_ok() { printf 'OK:%s\n' "$*"; }
  _print_next_steps host 1 0
)"
case "$partial_steps" in
*"Pangolin site is installed."*) ;;
*) echo "partial next steps missing the site: $partial_steps" >&2; exit 1 ;;
esac
case "$partial_steps" in
*"Pangolin client is installed."* | *"service status client"*)
  echo "partial next steps must not advertise the failed client: $partial_steps" >&2
  exit 1
  ;;
esac

echo "Entry tests passed"
echo "Orchestration tests passed"
