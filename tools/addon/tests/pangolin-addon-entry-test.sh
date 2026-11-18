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

# Task 1 multi-site helpers. A slug is a local site label; the suffix
# normalization lets hyphenated slugs resolve through Bash indirect expansion.
for ok in default a org-a abcdefghij; do
  validate_site_slug "$ok" || { echo "slug [$ok] should pass" >&2; exit 1; }
done
for bad in 1a -a a- A org_a abcdefghijk "" "or g" $'a\nb'; do
  if validate_site_slug "$bad" >/dev/null 2>&1; then
    echo "slug [$bad] should fail" >&2
    exit 1
  fi
done

# The slug `host` is reserved: it is the host target's environment suffix.
if validate_site_slug host >/dev/null 2>&1; then
  echo "reserved slug [host] should fail" >&2
  exit 1
fi
reserved_rc=0
reserved_out="$(_parse_sites 'host' 2>&1)" || reserved_rc=$?
[[ "$reserved_rc" -ne 0 ]] || { echo "slug host should be rejected" >&2; exit 1; }
case "$reserved_out" in
*Reserved*host*) ;;
*) echo "reserved slug message: $reserved_out" >&2; exit 1 ;;
esac
for bad in 'orga,host' 'default host'; do
  if _parse_sites "$bad" >/dev/null 2>&1; then
    echo "slug list [$bad] should fail" >&2
    exit 1
  fi
done

assert_eq $'orga\norg-b' "$(_parse_sites 'orga, org-b')"
assert_eq $'a\nb\nc\nd\ne\nf\ng\nh' "$(_parse_sites 'a b,c d,e f,g h')"
dup_sites_rc=0
dup_sites_out="$(_parse_sites 'orga orga' 2>&1)" || dup_sites_rc=$?
[[ "$dup_sites_rc" -ne 0 ]] || { echo "duplicate slug should fail" >&2; exit 1; }
case "$dup_sites_out" in
*Duplicate*orga*) ;;
*) echo "duplicate slug message: $dup_sites_out" >&2; exit 1 ;;
esac
for bad in 'orga,1' 'Org' 'org_a' '-a' 'a-'; do
  if _parse_sites "$bad" >/dev/null 2>&1; then
    echo "slug list [$bad] should fail" >&2
    exit 1
  fi
done
for empty in '' '   ' ',,'; do
  empty_rc=0
  empty_sites_out="$(_parse_sites "$empty" 2>&1)" || empty_rc=$?
  [[ "$empty_rc" -ne 0 ]] || { echo "empty selection [$empty] should fail" >&2; exit 1; }
  case "$empty_sites_out" in
  *"No sites selected"*) ;;
  *) echo "empty selection message [$empty]: $empty_sites_out" >&2; exit 1 ;;
  esac
done
nine_slugs="$(for i in 1 2 3 4 5 6 7 8 9; do printf 's%s ' "$i"; done)"
eight_slugs="$(for i in 1 2 3 4 5 6 7 8; do printf 's%s ' "$i"; done)"
cap_rc=0
cap_out="$(_parse_sites "$nine_slugs" 2>&1)" || cap_rc=$?
[[ "$cap_rc" -ne 0 ]] || { echo "nine slugs should exceed the cap" >&2; exit 1; }
case "$cap_out" in
*"maximum 8"*) ;;
*) echo "slug cap message: $cap_out" >&2; exit 1 ;;
esac
assert_eq "8" "$(_parse_sites "$eight_slugs" | grep -c .)"

# Wildcard input must fail validation, never expand against the working
# directory. The scratch dirs hold files that `*`, `?`, and `[ab]` would match.
globd="$(mktemp -d)"
mkdir -p "$globd/slugs" "$globd/targets"
touch "$globd/slugs/a" "$globd/slugs/ab" "$globd/slugs/b"
touch "$globd/targets/101" "$globd/targets/102"
for bad in '*' '?' '[ab]' '*.json'; do
  glob_out="$(cd "$globd/slugs" && _parse_sites "$bad" 2>&1)" && {
    echo "slug list [$bad] expanded working-directory files: $glob_out" >&2
    exit 1
  }
  case "$glob_out" in
  *"Invalid site slug"*) ;;
  *) echo "slug wildcard message [$bad]: $glob_out" >&2; exit 1 ;;
  esac
done
glob_targets="$(cd "$globd/targets" && _parse_targets '*' 2>&1)" && {
  echo "target list [*] expanded working-directory files: $glob_targets" >&2
  exit 1
}
case "$glob_targets" in
*"Invalid target"*) ;;
*) echo "target wildcard message: $glob_targets" >&2; exit 1 ;;
esac
assert_eq $'a\nab\nb' "$(cd "$globd/slugs" && _parse_sites 'a, ab b')"
assert_eq $'101\n102' "$(cd "$globd/targets" && _parse_targets '101, 102')"
rm -rf "$globd"

assert_eq "org_a" "$(_slug_suffix org-a)"
assert_eq "default" "$(_slug_suffix default)"

# _site_value resolves (slug,target) combined, slug-only when one target is
# selected, target-only when one slug is selected, then the global. Empty
# suffixed variables fall through to the next form.
assert_eq "wins" "$(
  var_site_id_org_a_101=wins var_site_id_org_a=slug-only \
    var_site_id_101=target-only var_site_id=global \
    _site_value var_site_id org-a 101 2 2
)"
assert_eq "slug-only" "$(
  var_site_id_org_a=slug-only var_site_id=global \
    _site_value var_site_id org-a 101 2 1
)"
assert_eq "target-only" "$(
  var_site_id_101=target-only var_site_id=global \
    _site_value var_site_id default 101 1 2
)"
assert_eq "global" "$(var_site_id=global _site_value var_site_id default 101 1 1)"
assert_eq "global" "$(
  var_site_id_org_a_host= var_site_id=global \
    _site_value var_site_id org-a host 1 1
)"
assert_eq "" "$(_site_value var_site_unset org-a 101 2 2)"

validate_unique_site_ids $'id-a\nid-b' || { echo "distinct site ids should pass" >&2; exit 1; }
validate_unique_site_ids $'id-a\n\nid-b\n' || { echo "empty lines should be ignored" >&2; exit 1; }
validate_unique_site_ids '' || { echo "no ids should pass" >&2; exit 1; }
# An id that only contains another id is not a duplicate.
validate_unique_site_ids $'x y\ny' || { echo "substring ids are not duplicates" >&2; exit 1; }
site_dup_rc=0
site_dup_out="$(validate_unique_site_ids $'id-a\nid-b\nid-a' 2>&1)" || site_dup_rc=$?
[[ "$site_dup_rc" -ne 0 ]] || { echo "duplicate site id should fail" >&2; exit 1; }
case "$site_dup_out" in
*"Duplicate site ID"*id-a*) ;;
*) echo "duplicate site id message: $site_dup_out" >&2; exit 1 ;;
esac

validate_unique_client_ids $'cid-a\ncid-b\n\ncid-c' ||
  { echo "distinct client ids should pass" >&2; exit 1; }
client_dup_rc=0
client_dup_out="$(validate_unique_client_ids $'cid-a\ncid-a' 2>&1)" || client_dup_rc=$?
[[ "$client_dup_rc" -ne 0 ]] || { echo "duplicate client id should fail" >&2; exit 1; }
case "$client_dup_out" in
*"Duplicate client ID"*cid-a*) ;;
*) echo "duplicate client id message: $client_dup_out" >&2; exit 1 ;;
esac

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
*"manage multiple site labels"*) printf '%s' "${FAKE_SITEMODE_OUT:-one}" >&2 ;;
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
  printf 'client\n' >"\$answers/verified"
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

# A failed payload can still record verified components. The recorded client
# is tagged and summarized even though the target failed, while the run exits
# non-zero and the later target continues.
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
grep -q 'pct set 101 -tags.*pangolin-client' "$loop/log" ||
  { echo "the verified client on the partial target must be tagged: $loop/log" >&2; exit 1; }
if grep -q 'pct set 101 -tags.*pangolin-site' "$loop/log"; then
  echo "an unverified component must not be tagged" >&2
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

# Multi-site Task 2: interface defaults, SSH ownership mapping, and answers
# written to an exact per-slug path. The generators live in the entry so the
# dry run can name interfaces before any payload fetch.
assert_eq pangorga "$(default_site_interface orga)"
assert_eq pangmorga "$(default_site_interface_main orga)"
assert_eq pangdefault "$(default_site_interface default)"
assert_eq pangabcdefghij "$(default_site_interface abcdefghij)"
assert_eq pangmabcdefghij "$(default_site_interface_main abcdefghij)"
assert_eq "14" "$(printf '%s' "$(default_site_interface abcdefghij)" | wc -c)"
assert_eq "15" "$(printf '%s' "$(default_site_interface_main abcdefghij)" | wc -c)"
longest="$(default_site_interface_main abcdefghij)"
[[ "${#longest}" -le 15 ]] || { echo "default interface exceeds IFNAMSIZ: $longest" >&2; exit 1; }
validate_interface_name "$longest" ||
  { echo "default interface [$longest] should be valid" >&2; exit 1; }

# Exactly one slug owns the embedded SSH daemon; every other slug disables it.
site_ssh_disabled default default && { echo "owner slug must keep SSH" >&2; exit 1; }
site_ssh_disabled default orga || { echo "non-owner slug must disable SSH" >&2; exit 1; }
site_ssh_disabled orga orga && { echo "owner slug must keep SSH" >&2; exit 1; }
site_ssh_disabled orga default || { echo "default is not the owner here" >&2; exit 1; }
site_ssh_disabled "" orga || { echo "empty owner must disable SSH" >&2; exit 1; }
site_ssh_disabled "" default || { echo "empty owner must disable the default slug" >&2; exit 1; }
site_ssh_disabled none default || { echo "owner none must disable SSH" >&2; exit 1; }
site_ssh_disabled none orga || { echo "owner none must disable SSH for every slug" >&2; exit 1; }

# The SSH owner must be empty, none, or an exact slug from the list.
validate_site_ssh_owner default $'default\norga' ||
  { echo "owner default should pass" >&2; exit 1; }
validate_site_ssh_owner none $'default\norga' ||
  { echo "owner none should pass" >&2; exit 1; }
validate_site_ssh_owner "" $'default\norga' ||
  { echo "empty owner should pass" >&2; exit 1; }
validate_site_ssh_owner orga $'default\norga' ||
  { echo "slug owner should pass" >&2; exit 1; }
for bad_owner in hostr orgad org sub; do
  owner_rc=0
  owner_out="$(validate_site_ssh_owner "$bad_owner" $'default\norga' 2>&1)" || owner_rc=$?
  [[ "$owner_rc" -ne 0 ]] || { echo "owner [$bad_owner] should fail" >&2; exit 1; }
  case "$owner_out" in
  *"SSH owner"*) ;;
  *) echo "ssh owner message [$bad_owner]: $owner_out" >&2; exit 1 ;;
  esac
done

# Interface names must be unique; the message names only interfaces.
interface_names_unique $'pangorga\npangmorga' ||
  { echo "distinct interface names should pass" >&2; exit 1; }
interface_names_unique $'pangorga\n\npangmorga\n' ||
  { echo "blank lines should be ignored" >&2; exit 1; }
interface_names_unique '' || { echo "no names should pass" >&2; exit 1; }
iface_dup_rc=0
iface_dup_out="$(interface_names_unique $'pangorga\npangorga' 2>&1)" || iface_dup_rc=$?
[[ "$iface_dup_rc" -ne 0 ]] || { echo "duplicate interface name should fail" >&2; exit 1; }
case "$iface_dup_out" in
*Duplicate*pangorga*) ;;
*) echo "duplicate interface message: $iface_dup_out" >&2; exit 1 ;;
esac

# A path-aware builder writes any nested config path with private modes and
# validates before creating anything.
p2dir="$(mktemp -d)"
build_site_answers_to_path "$p2dir/etc/pangolin/sites/org-a.json" \
  "https://p.example" - - id secret 1 1 pangorga pangmorga 1 ||
  { echo "path-aware answers failed" >&2; exit 1; }
sites_dir="$(dirname "$p2dir/etc/pangolin/sites/org-a.json")"
[[ "$(stat -c '%a' "$sites_dir")" == "700" ]] ||
  { echo "sites dir mode $(stat -c '%a' "$sites_dir")" >&2; exit 1; }
[[ "$(stat -c '%a' "$p2dir/etc/pangolin/sites/org-a.json")" == "600" ]] ||
  { echo "site config mode" >&2; exit 1; }
assert_eq \
  '{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangorga","nativeMain":true,"interfaceMain":"pangmorga","disableSsh":true}' \
  "$(<"$p2dir/etc/pangolin/sites/org-a.json")"
build_site_answers_to_path "$p2dir/keys.json" \
  "https://p.example" "spk-1.key" "pve-1" - - 0 0 pangolin pangolin 0 ||
  { echo "provisioning path answers failed" >&2; exit 1; }
python3 - "$p2dir/keys.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["provisioningKey"] == "spk-1.key", d
assert "disableSsh" not in d, d
assert "native" not in d, d
PY
badp="$p2dir/missing-dir/site.json"
if build_site_answers_to_path "$badp" "not-a-url" - - id secret \
  >/dev/null 2>&1; then
  echo "invalid endpoint should fail" >&2; exit 1
fi
[[ ! -e "$badp" ]] || { echo "invalid endpoint must not create the file" >&2; exit 1; }
[[ ! -e "$(dirname "$badp")" ]] ||
  { echo "invalid endpoint must not create the parent directory" >&2; exit 1; }
if build_site_answers_to_path "$badp" "https://p.example" - - "-" - \
  >/dev/null 2>&1; then
  echo "missing credentials should fail" >&2; exit 1
fi
[[ ! -e "$badp" && ! -e "$(dirname "$badp")" ]] ||
  { echo "failed credential check must not write" >&2; exit 1; }
if build_site_answers_to_path "$badp" "https://p.example" - - id secret 1 1 pangorga pangmorga yes \
  >/dev/null 2>&1; then
  echo "invalid disableSsh flag should fail" >&2; exit 1
fi

# build_site_answers keeps writing <dir>/site.json, delegates to the path
# builder, and passes the disableSsh argument through.
build_site_answers "$p2dir/ssh" "https://p.example" - - id secret \
  1 1 pangorga pangmorga 1 || { echo "ssh-disabled answers" >&2; exit 1; }
assert_eq \
  '{"endpoint":"https://p.example","id":"id","secret":"secret","native":true,"interface":"pangorga","nativeMain":true,"interfaceMain":"pangmorga","disableSsh":true}' \
  "$(<"$p2dir/ssh/site.json")"
[[ "$(stat -c '%a' "$p2dir/ssh")" == "700" ]] ||
  { echo "answers dir mode" >&2; exit 1; }
build_site_answers "$p2dir/plain" "https://p.example" - - id secret \
  0 0 pangolin pangolin || { echo "ten-argument answers" >&2; exit 1; }
python3 - "$p2dir/plain/site.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "disableSsh" not in d, d
assert "native" not in d, d
PY
build_site_answers "$p2dir/sshbad" "https://p.example" - - id secret \
  0 0 pangolin pangolin yes >/dev/null 2>&1 && {
  echo "invalid disableSsh flag should fail" >&2; exit 1
}
[[ ! -e "$p2dir/sshbad/site.json" ]] ||
  { echo "failed validation must not write answers" >&2; exit 1; }
rm -rf "$p2dir"

# Interface collision checks: a fake `ip` says eth0 exists; a fake `pct`
# records the exec call for LXC targets.
iface="$(mktemp -d)"
mkdir -p "$iface/bin"
cat >"$iface/bin/ip" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "link show" ]] || exit 1
[[ "${3:-}" == eth0 ]] && exit 0
exit 1
EOF
cat >"$iface/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$IFACE_LOG"
[[ "${1:-}" == exec && "${2:-}" == 101 ]] || exit 1
shift 3
[[ "${1:-} ${2:-} ${3:-}" == "ip link show" ]] || exit 1
[[ "${4:-}" == eth0 ]] && exit 0
exit 1
EOF
chmod 755 "$iface/bin/ip" "$iface/bin/pct"
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  _interface_exists_on_target host eth0 ||
  { echo "fake ip should report eth0" >&2; exit 1; }
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  _interface_exists_on_target host pangorga && {
  echo "fake ip should not report pangorga" >&2; exit 1
}
: >"$iface/log"
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  _interface_exists_on_target 101 eth0 ||
  { echo "fake pct should report eth0 on 101" >&2; exit 1; }
grep -q 'pct exec 101 -- ip link show eth0' "$iface/log" ||
  { echo "LXC check must use pct exec" >&2; exit 1; }
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target host $'pangorga\npangmorga' ||
  { echo "free names should pass" >&2; exit 1; }
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target host $'pangorga\neth0' >/dev/null 2>&1 && {
  echo "an existing interface should fail" >&2; exit 1
}
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target 101 $'pangorga\neth0' >/dev/null 2>&1 && {
  echo "an existing LXC interface should fail" >&2; exit 1
}
dup_rc=0
dup_out="$(IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target host $'pangorga\npangorga' 2>&1)" || dup_rc=$?
[[ "$dup_rc" -ne 0 ]] || { echo "duplicate names should fail" >&2; exit 1; }
case "$dup_out" in
*Duplicate*) ;;
*) echo "duplicate name message: $dup_out" >&2; exit 1 ;;
esac
blank_rc=0
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target host $'pangorga\n\npangmorga' >/dev/null 2>&1 ||
  blank_rc=$?
[[ "$blank_rc" -ne 0 ]] || { echo "blank names should fail" >&2; exit 1; }
IFACE_LOG="$iface/log" PATH="$iface/bin:$PATH" \
  validate_interface_names_on_target host $'pang\neth0\npangm' >/dev/null 2>&1 && {
  echo "the existing name in the middle should fail" >&2; exit 1
}
if grep -q 'id\|secret' "$iface/log"; then
  echo "interface validation must not consult credentials" >&2; exit 1
fi
rm -rf "$iface"

# ---------------------------------------------------------------------------
# Multi-site Task 6: entry orchestration and the payload multi-slug loop.
# ---------------------------------------------------------------------------

# Slug resolution order: the per-target list wins, then the global list,
# then `default`.
assert_eq default "$(_sites_for_target host)"
assert_eq $'orga\norgb' "$(var_sites='orga, orgb' _sites_for_target host)"
assert_eq $'orgb\norgc' "$(var_sites='orga' var_sites_101='orgb orgc' _sites_for_target 101)"

# Boolean normalization accepts the common spellings consistently.
assert_eq 1 "$(_normalize_bool true)"
assert_eq 1 "$(_normalize_bool yes)"
assert_eq 1 "$(_normalize_bool 1)"
assert_eq 0 "$(_normalize_bool 0)"
assert_eq 0 "$(_normalize_bool false)"
assert_eq 0 "$(_normalize_bool no)"
assert_eq 0 "$(_normalize_bool '')"

# Interface override resolution per (slug,target) pair, with the per-slug
# generated default and the shared global fallback.
assert_eq pangorga "$(_site_pair_interface orga host 1 1 client)"
assert_eq pangmorga "$(_site_pair_interface orga host 1 1 main)"
assert_eq myiface "$(var_site_interface_org_a=myiface _site_pair_interface org-a host 1 1 client)"
assert_eq mainmy "$(var_site_interface_main_orga=mainmy _site_pair_interface orga host 1 1 main)"
assert_eq shared "$(var_site_interface=shared _site_pair_interface orgb 101 2 2 client)"
assert_eq "bt" "$(
  var_site_interface_orgb_101=bt var_site_interface_orgb=ignored \
    _site_pair_interface orgb 101 2 2 client
)"

# The enabled-interface collector emits exactly the enabled names, never an
# empty line (validate_interface_names_on_target rejects trailing empties), and
# prints nothing when no native mode is enabled.
assert_eq "" "$(var_site_native=0 var_site_native_main=0 \
  _collect_site_interfaces host 1 1 default orgb)"
assert_eq $'pangdefault\npangmdefault\npangorgb\npangmorgb' "$(
  var_site_native=1 var_site_native_main=1 _collect_site_interfaces host 1 1 default orgb
)"
assert_eq pangorgb "$(var_site_native=1 var_site_native_main=0 \
  _collect_site_interfaces host 1 1 orgb)"

# Carry-forward: a relative or dot-parent answers path must be rejected before
# any mode change or write.
rel6="$(mktemp -d)"
if (cd "$rel6" && build_site_answers_to_path "sites/x.json" "https://p.example" - - id secret \
  >/dev/null 2>&1); then
  echo "relative answers path should fail" >&2; exit 1
fi
[[ ! -e "$rel6/sites" ]] || { echo "relative path must not create directories" >&2; exit 1; }
if (cd "$rel6" && build_site_answers_to_path "./site.json" "https://p.example" - - id secret \
  >/dev/null 2>&1); then
  echo "dot-parent answers path should fail" >&2; exit 1
fi
rm -rf "$rel6"

# Carry-forward: an SSH owner with control characters is sanitized so operator
# input cannot forge a second log line.
inj_rc=0
inj_out="$(validate_site_ssh_owner $'evil\nFORGED-MARKER' $'default' 2>&1)" || inj_rc=$?
[[ "$inj_rc" -ne 0 ]] || { echo "control-char owner should fail" >&2; exit 1; }
case "$inj_out" in
*FORGED-MARKER*) ;;
*) echo "owner error should keep the sanitized marker: $inj_out" >&2; exit 1 ;;
esac
[[ "$(printf '%s' "$inj_out" | wc -l)" == 0 ]] ||
  { echo "owner error must stay one line: $inj_out" >&2; exit 1; }

# Multi-site loop fixture. The fake payload snapshots the answers directory per
# target, emits per-slug verified markers, and honors one failing slug.
s6="$(mktemp -d)"
mkdir -p "$s6/bin" "$s6/tmp" "$s6/remote" "$s6/snap" "$s6/fakeroot"
cat >"$s6/bin/pct" <<'EOF'
#!/usr/bin/env bash
echo "pct $*" >>"$FAKE_LOG"
ctid="$2"
case "$1" in
config) printf 'tags: old;pangolin-cli\n' ;;
list) printf 'VMID Status Lock Name\n101 running c1\n102 running c2\n' ;;
set) exit 0 ;;
status) printf 'status: running\n' ;;
start | shutdown) exit 0 ;;
push)
  src="$3"
  dst="${4#/root/.pangolin-addon/}"
  mkdir -p "$FAKE_REMOTE_DIR/$ctid/$(dirname "$dst")"
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
  *chmod*) : ;;
  *payload.sh*) bash "$dir/payload.sh" "$dir" ;;
  *"ip link show "*[![:space:]]*)
    name="${*##*ip link show }"
    [[ " ${FAKE_CT_IP_EXISTS:-} " == *" $name "* ]]
    ;;
  *"ip link show"*) exit 1 ;;
  *"test -f /etc/pangolin/sites/"*)
    path="${*##*test -f }"
    path="${path%% *}"
    [[ -f "$FAKE_CT_ROOT/$ctid/$path" ]]
    ;;
  *"ls -1 /etc/pangolin/sites"*)
    ls -1 "$FAKE_CT_ROOT/$ctid/etc/pangolin/sites" 2>/dev/null || true
    ;;
  *"test -f /etc/pangolin/site.json"*)
    [[ -f "$FAKE_CT_ROOT/$ctid/etc/pangolin/site.json" ]]
    ;;
  *site-layout*|*"pangolin-site@"*) printf '%s\n' "${FAKE_CT_LAYOUT:-single}" ;;
  *hostname*) printf 'ct%s\n' "$ctid" ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
EOF
cat >"$s6/bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >>"$FAKE_LOG"
[[ "${1:-} ${2:-}" == "link show" ]] || exit 1
[[ -n "${3:-}" ]] || exit 1
[[ " ${FAKE_IP_EXISTS:-} " == *" ${3:-} "* ]]
EOF
cat >"$s6/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_WHIPTAIL_LOG"
case "$*" in
*"manage multiple site labels"*) printf '%s' "${FAKE_SITEMODE_OUT:-one}" >&2 ;;
*"Site labels"*checklist*|*--checklist*"Site labels"*)
  if [[ -n "${FAKE_SITES_SEQ:-}" ]]; then
    n=0
    if [[ -f "${FAKE_SITES_SEQ}.n" ]]; then n="$(cat "${FAKE_SITES_SEQ}.n")"; fi
    n=$((n + 1))
    printf '%s' "$n" >"${FAKE_SITES_SEQ}.n"
    sed -n "${n}p" "$FAKE_SITES_SEQ" | tr -d '\n' >&2
  else
    printf '%s' "${FAKE_SITES_OUT:-}" >&2
  fi
  ;;
*"New site label"*) printf '%s' "${FAKE_SLUG_ADD:-}" >&2 ;;
*"Site SSH owner"*) printf '%s' "${FAKE_OWNER_OUT:-}" >&2 ;;
*"Targets (space selects"*) printf '%s' "${FAKE_TARGETS_OUT:-}" >&2 ;;
*"Site networking:"*) printf '%s' "${FAKE_NATIVE_OUT:-}" >&2 ;;
*"Site credentials:"*) printf 'static' >&2 ;;
*"Existing site"*) printf 'replace' >&2 ;;
*"Select components"*) printf '%s' "${FAKE_MODE_OUT:-client}" >&2 ;;
*"Pangolin endpoint"*) printf '%s' "${FAKE_ENDPOINT_OUT:-https://p.example}" >&2 ;;
*"Site ID"*) printf 'id' >&2 ;;
*"Site secret"*) printf 'sec' >&2 ;;
*"Site name"*) printf 'pve' >&2 ;;
*"Machine client ID"*) printf 'cid' >&2 ;;
*"Machine client secret"*) printf 'csec' >&2 ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$s6/bin/pct" "$s6/bin/ip" "$s6/bin/whiptail"
cat >"$s6/payload.sh" <<EOF
#!/usr/bin/env bash
# Sourced by main, executed per target.
if [[ "\${BASH_SOURCE[0]:-}" != "\$0" ]]; then
  return 0
fi
answers="\${1:-}"
flags="\$answers/flags"
target="\$(sed -n 's/^TARGET=//p' "\$flags" 2>/dev/null)"
site="\$(sed -n 's/^SITE=//p' "\$flags" 2>/dev/null)"
client="\$(sed -n 's/^CLIENT=//p' "\$flags" 2>/dev/null)"
multi="\$(sed -n 's/^MULTI_SITE=//p' "\$flags" 2>/dev/null)"
slugs="\$(sed -n 's/^SITE_SLUGS=//p' "\$flags" 2>/dev/null)"
printf '%s\n' "\$target" >>"$s6/ran"
mkdir -p "$s6/snap/\$target"
cp -a "\$answers"/. "$s6/snap/\$target/"
if [[ "\$target" == "\$(cat "$s6/fail-target" 2>/dev/null)" ]]; then
  exit 1
fi
fail_slug="\$(cat "$s6/fail-slug" 2>/dev/null)"
multi_fail=0
{
  printf 'backend:systemd\n'
  if [[ "\$site" == 1 && "\$multi" == 1 ]]; then
    for slug in \$slugs; do
      if [[ -n "\$fail_slug" && "\$slug" == "\$fail_slug" ]]; then
        multi_fail=1
        continue
      fi
      printf 'site:%s\n' "\$slug"
    done
    for slug in \$slugs; do
      [[ "\$slug" == default ]] || continue
      if [[ -n "\$fail_slug" && "\$slug" == "\$fail_slug" ]]; then
        continue
      fi
      printf 'site\n'
    done
  elif [[ "\$site" == 1 ]]; then
    printf 'site\n'
  fi
  if [[ "\$client" == 1 ]]; then
    printf 'client\n'
  fi
} >"\$answers/verified"
if [[ "\$multi_fail" == 1 ]]; then
  exit 1
fi
EOF
: >"$s6/fail-target"
: >"$s6/fail-slug"

_run6() {
  (
    export PATH="$s6/bin:$PATH"
    export FAKE_LOG="$s6/log" FAKE_REMOTE_DIR="$s6/remote" TMPDIR="$s6/tmp"
    export FAKE_WHIPTAIL_LOG="$s6/wlog" PANGOLIN_ROOT="$s6/fakeroot"
    _ensure_curl() { :; }
    _load_core() { :; }
    require_pve_host() { return 0; }
    header_info() { :; }
    msg_info() { printf 'INFO:%s\n' "$*"; }
    msg_ok() { printf 'OK:%s\n' "$*"; }
    msg_warn() { printf 'WARN:%s\n' "$*" >&2; }
    msg_error() { printf 'ERROR:%s\n' "$*" >&2; }
    _ensure_lxc_running() { :; }
    _validate_target_os() { :; }
    _apply_lxc_tun() { :; }
    _ensure_lxc_runtime() { :; }
    _ensure_host_tun() { :; }
    fetch_payload() { install -m 0600 "$s6/payload.sh" "$1"; }
    main
  )
}
_reset6() {
  rm -rf "$s6/snap" "$s6/remote" "$s6/fakeroot"
  mkdir -p "$s6/snap" "$s6/remote" "$s6/fakeroot"
  : >"$s6/log"
  : >"$s6/ran"
}

# E1: the default single-slug variables still write site.json and take the
# legacy payload path.
_reset6
if ! e1_out="$(var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
  var_site_id=e1id var_site_secret=e1sec _run6 2>&1)"; then
  echo "E1 single-slug run failed: $e1_out" >&2; exit 1
fi
grep -qx 'MULTI_SITE=0' "$s6/snap/host/flags" ||
  { echo "E1 legacy run must set MULTI_SITE=0" >&2; exit 1; }
[[ -f "$s6/snap/host/site.json" ]] || { echo "E1 site.json missing" >&2; exit 1; }
[[ ! -e "$s6/snap/host/sites" ]] || { echo "E1 must not write sites/" >&2; exit 1; }

# E2: two slugs generate per-slug answers per target with MULTI_SITE=1.
_reset6
if ! e2_out="$(var_mode=site var_targets="host 101" var_sites="default orgb" \
  var_pangolin_endpoint=https://p.example \
  var_site_id_default_host=did var_site_secret_default_host=dsec \
  var_site_id_orgb_host=oid var_site_secret_orgb_host=osec \
  var_site_id_default_101=di1 var_site_secret_default_101=dis1 \
  var_site_id_orgb_101=oi1 var_site_secret_orgb_101=ois1 _run6 2>&1)"; then
  echo "E2 multi-slug run failed: $e2_out" >&2; exit 1
fi
for snapdir in host 101; do
  f="$s6/snap/$snapdir/flags"
  grep -qx 'SITE_SLUGS=default orgb' "$f" || { echo "E2 SITE_SLUGS missing" >&2; exit 1; }
  grep -qx 'MULTI_SITE=1' "$f" || { echo "E2 MULTI_SITE=1 missing" >&2; exit 1; }
  grep -qx 'SSH_OWNER=default' "$f" || { echo "E2 SSH_OWNER missing" >&2; exit 1; }
  [[ -f "$s6/snap/$snapdir/sites/default.json" ]] ||
    { echo "E2 sites/default.json missing" >&2; exit 1; }
  [[ -f "$s6/snap/$snapdir/sites/orgb.json" ]] ||
    { echo "E2 sites/orgb.json missing" >&2; exit 1; }
  [[ ! -e "$s6/snap/$snapdir/site.json" ]] ||
    { echo "E2 must not write the legacy site.json" >&2; exit 1; }
  if [[ "$snapdir" == host ]]; then
    # The host snapshot copies the real local answers tree. The remote copy
    # goes through the fake pct push, which does not model directory modes.
    [[ "$(stat -c '%a' "$s6/snap/$snapdir/sites")" == "700" ]] ||
      { echo "E2 sites dir mode" >&2; exit 1; }
  fi
done
python3 - "$s6/snap/host/sites/orgb.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["disableSsh"] is True, d
assert d["id"] == "oid", d
PY
python3 - "$s6/snap/host/sites/default.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "disableSsh" not in d, d
assert d["id"] == "did", d
PY
# Cleanup: every remote answers directory is gone after the multi-slug run.
[[ -z "$(ls -A "$s6/remote")" ]] || { echo "E2 remote answers left" >&2; exit 1; }
[[ -z "$(ls -A "$s6/tmp")" ]] || { echo "E2 local answers left" >&2; exit 1; }
grep -q 'pct exec 101 -- rm -rf /root/.pangolin-addon' "$s6/log" ||
  { echo "E2 remote cleanup missing" >&2; exit 1; }
if grep -q 'osec\|ois1\|dsec\|dis1' "$s6/log"; then
  echo "E2 secret reached the pct log" >&2; exit 1
fi

# E3: var_sites_101 overrides the global list for one target.
_reset6
if ! e3_out="$(var_mode=site var_targets="host 101" var_sites="orga" var_sites_101="orgb" \
  var_pangolin_endpoint=https://p.example \
  var_site_id_orga_host=a1 var_site_secret_orga_host=as1 \
  var_site_id_orgb_101=b1 var_site_secret_orgb_101=bs1 _run6 2>&1)"; then
  echo "E3 per-target slug list failed: $e3_out" >&2; exit 1
fi
grep -qx 'SITE_SLUGS=orga' "$s6/snap/host/flags" ||
  { echo "E3 host slug list wrong" >&2; exit 1; }
grep -qx 'SITE_SLUGS=orgb' "$s6/snap/101/flags" ||
  { echo "E3 101 slug list wrong" >&2; exit 1; }
[[ -f "$s6/snap/host/sites/orga.json" && -f "$s6/snap/101/sites/orgb.json" ]] ||
  { echo "E3 per-target configs missing" >&2; exit 1; }

# E5: a duplicate static site ID across slug/target pairs fails before any
# pct call or payload run.
_reset6
e5_rc=0
e5_out="$(var_mode=site var_target=101 var_sites="orga orgb" \
  var_pangolin_endpoint=https://p.example \
  var_site_id_orga=dup var_site_secret_orga=s1 var_site_id_orgb=dup var_site_secret_orgb=s2 \
  _run6 2>&1)" || e5_rc=$?
[[ "$e5_rc" -ne 0 ]] || { echo "E5 duplicate site id should fail" >&2; exit 1; }
case "$e5_out" in
*"Duplicate site ID"*dup*) ;;
*) echo "E5 duplicate site id message: $e5_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" ]] || { echo "E5 payload ran despite duplicate" >&2; exit 1; }
[[ ! -s "$s6/log" ]] || { echo "E5 pct touched before validation" >&2; exit 1; }

# E6: one shared provisioning key across two targets still succeeds.
_reset6
if ! e6_out="$(var_mode=site var_targets="host 101" var_pangolin_endpoint=https://p.example \
  var_site_provisioning_key_host=spk-shared var_site_provisioning_key_101=spk-shared \
  _run6 2>&1)"; then
  echo "E6 shared provisioning key failed: $e6_out" >&2; exit 1
fi
assert_eq $'host\n101' "$(cat "$s6/ran")"
grep -qx 'MULTI_SITE=0' "$s6/snap/host/flags" ||
  { echo "E6 must stay on the legacy path" >&2; exit 1; }
python3 - "$s6/snap/host/site.json" "$s6/snap/101/site.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    d = json.load(open(path))
    assert d["provisioningKey"] == "spk-shared", d
PY

# E7: duplicate client IDs fail before any side effect.
_reset6
e7_rc=0
e7_out="$(var_mode=client var_targets="host 101" var_pangolin_endpoint=https://p.example \
  var_client_id_host=dupcid var_client_secret_host=s1 \
  var_client_id_101=dupcid var_client_secret_101=s2 _run6 2>&1)" || e7_rc=$?
[[ "$e7_rc" -ne 0 ]] || { echo "E7 duplicate client id should fail" >&2; exit 1; }
case "$e7_out" in
*"Duplicate client ID"*dupcid*) ;;
*) echo "E7 duplicate client id message: $e7_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" ]] || { echo "E7 payload ran despite duplicate" >&2; exit 1; }
[[ ! -s "$s6/log" ]] || { echo "E7 pct touched before validation" >&2; exit 1; }

# E8: the SSH owner must exist among the selected slugs or be none.
_reset6
e8_rc=0
e8_out="$(var_mode=site var_target=101 var_sites="orga orgb" var_site_ssh_owner=orgc \
  var_pangolin_endpoint=https://p.example \
  var_site_id_orga=i1 var_site_secret_orga=s1 var_site_id_orgb=i2 var_site_secret_orgb=s2 \
  _run6 2>&1)" || e8_rc=$?
[[ "$e8_rc" -ne 0 ]] || { echo "E8 unknown owner should fail" >&2; exit 1; }
case "$e8_out" in
*"Invalid site SSH owner: orgc"*) ;;
*) echo "E8 owner message: $e8_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" && ! -s "$s6/log" ]] ||
  { echo "E8 owner validation must run first" >&2; exit 1; }

# E8b: two slugs overriding to the same interface name fail before any side
# effect.
e8b_rc=0
e8b_out="$(var_mode=site var_target=101 var_sites="orga orgb" var_site_native=1 \
  var_site_interface_orga=dupiface var_site_interface_orgb=dupiface \
  var_pangolin_endpoint=https://p.example \
  var_site_id_orga=i1 var_site_secret_orga=s1 var_site_id_orgb=i2 var_site_secret_orgb=s2 \
  _run6 2>&1)" || e8b_rc=$?
[[ "$e8b_rc" -ne 0 ]] || { echo "E8b interface collision should fail" >&2; exit 1; }
case "$e8b_out" in
*"Duplicate interface name: dupiface"*) ;;
*) echo "E8b collision message: $e8b_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" && ! -s "$s6/log" ]] ||
  { echo "E8b interface validation must run first" >&2; exit 1; }

# E9: the multi-target x multi-slug dry run lists slugs, owner, and interface
# names, prints no secret, and touches no network, pct, or ip.
_reset6
if ! e9_out="$(TMPDIR="$s6/tmp" PATH="$s6/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 \
  var_mode=site var_targets="host,101" var_sites="orga orgb" var_site_ssh_owner=orga \
  var_site_native=1 var_site_native_main=1 var_pangolin_endpoint=https://p.example \
  var_site_id_orga_host=a1 var_site_secret_orga_host=DRY-SEC-A1 \
  var_site_id_orgb_host=b1 var_site_secret_orgb_host=DRY-SEC-B1 \
  var_site_id_orga_101=a2 var_site_secret_orga_101=DRY-SEC-A2 \
  var_site_id_orgb_101=b2 var_site_secret_orgb_101=DRY-SEC-B2 \
  bash "$ROOT/add-pangolin.sh" 2>&1)"; then
  echo "E9 multi-slug dry run failed: $e9_out" >&2; exit 1
fi
for token in "Sites: orga orgb" "SSH owner: orga" "pangorga" "pangmorga" "pangorgb" "pangmorgb"; do
  case "$e9_out" in
  *"$token"*) ;;
  *) echo "E9 dry run missing [$token]: $e9_out" >&2; exit 1 ;;
  esac
done
assert_eq "2" "$(printf '%s\n' "$e9_out" | grep -c '^Target: ')"
case "$e9_out" in
*DRY-SEC*) echo "E9 dry run printed a secret" >&2; exit 1 ;;
esac
[[ ! -s "$s6/log" ]] || { echo "E9 dry run used pct or ip" >&2; exit 1; }
[[ -z "$(ls -A "$s6/tmp")" ]] || { echo "E9 dry run wrote files" >&2; exit 1; }

# E10: a real multi-site partial failure. The payload exits non-zero after
# recording site:default and backend:systemd markers for the slug that did
# verify. The verified default is still tagged (one pangolin-site) and
# summarized, orgb is reported failed, the target is failed, and the run
# exits non-zero while the remote answers are still cleaned up.
_reset6
printf 'orgb\n' >"$s6/fail-slug"
e10_rc=0
e10_out="$(var_mode=site var_targets=101 var_sites="default orgb" \
  var_pangolin_endpoint=https://p.example \
  var_site_id_default_101=x var_site_secret_default_101=y \
  var_site_id_orgb_101=i3 var_site_secret_orgb_101=s3 \
  _run6 2>&1)" || e10_rc=$?
[[ "$e10_rc" -ne 0 ]] || { echo "E10 a failing slug must fail the run" >&2; exit 1; }
tag_line="$(grep 'pct set 101 -tags' "$s6/log")"
[[ -n "$tag_line" ]] ||
  { echo "E10 the verified default must still be tagged: $e10_out" >&2; exit 1; }
assert_eq "1" "$(printf '%s' "$tag_line" | grep -o 'pangolin-site' | wc -l)"
case "$e10_out" in
*"site default: verified"*) ;;
*) echo "E10 summary missing verified slug: $e10_out" >&2; exit 1 ;;
esac
case "$e10_out" in
*"site orgb: failed"*) ;;
*) echo "E10 summary missing failed slug: $e10_out" >&2; exit 1 ;;
esac
case "$e10_out" in
*"101: failed"*) ;;
*) echo "E10 the target itself must be reported failed: $e10_out" >&2; exit 1 ;;
esac
[[ -z "$(ls -A "$s6/remote")" ]] ||
  { echo "E10 remote answers left after a partial failure" >&2; exit 1; }
: >"$s6/fail-slug"

# Regression: a dry run must plan the generated interface names before any
# payload is fetched, so the name generators have to live in the entry.
_reset6
if ! nopay_dry="$(
  TMPDIR="$s6/tmp" PATH="$s6/bin:/usr/bin:/bin" PANGOLIN_DRY_RUN=1 PANGOLIN_PAYLOAD= \
    var_mode=site var_target=host var_sites=orga var_site_native=1 var_site_native_main=1 \
    var_pangolin_endpoint=https://p.example \
    var_site_id_orga=a1 var_site_secret_orga=b1 \
    bash "$ROOT/add-pangolin.sh" 2>&1)"; then
  echo "no-payload dry run failed: $nopay_dry" >&2; exit 1
fi
for token in "Sites: orga" "pangorga" "pangmorga"; do
  case "$nopay_dry" in
  *"$token"*) ;;
  *) echo "no-payload dry run missing [$token]: $nopay_dry" >&2; exit 1 ;;
  esac
done
case "$nopay_dry" in
*"command not found"*)
  echo "no-payload dry run missed an entry helper: $nopay_dry" >&2; exit 1
  ;;
esac
case "$nopay_dry" in
*a1* | *b1*) echo "no-payload dry run printed a secret" >&2; exit 1 ;;
esac
[[ ! -s "$s6/log" ]] || { echo "no-payload dry run used pct or ip" >&2; exit 1; }
[[ -z "$(ls -A "$s6/tmp")" ]] || { echo "no-payload dry run wrote files" >&2; exit 1; }

# Regression: credentials entered interactively for the default slug must
# reach the per-slug plan when the first target is already converted. The
# converted host uses sites/default.json with the typed values; the second,
# unconverted target stays on the legacy site.json path.
_reset6
mkdir -p "$s6/fakeroot/etc/systemd/system"
printf '[Unit]\n' >"$s6/fakeroot/etc/systemd/system/pangolin-site@.service"
: >"$s6/wlog"
if ! itc_out="$(
  var_mode= var_targets= var_target= var_sites= var_site_ssh_owner= \
    var_pangolin_endpoint= var_site_id= var_site_secret= \
    FAKE_MODE_OUT=site FAKE_TARGETS_OUT='"host"' _run6 2>&1)"; then
  echo "interactive converted-host run failed: $itc_out" >&2; exit 1
fi
assert_eq "host" "$(cat "$s6/ran")"
grep -qx 'MULTI_SITE=1' "$s6/snap/host/flags" ||
  { echo "the converted host must use the per-slug layout: $itc_out" >&2; exit 1; }
grep -qx 'SITE_SLUGS=default' "$s6/snap/host/flags" ||
  { echo "the converted host must list the default slug" >&2; exit 1; }
[[ -f "$s6/snap/host/sites/default.json" ]] ||
  { echo "the converted host must write sites/default.json" >&2; exit 1; }
grep -q '"id":"id"' "$s6/snap/host/sites/default.json" ||
  { echo "the entered site id must reach the converted host" >&2; exit 1; }
grep -q '"secret":"sec"' "$s6/snap/host/sites/default.json" ||
  { echo "the entered site secret must reach the converted host" >&2; exit 1; }
[[ ! -e "$s6/snap/host/site.json" ]] ||
  { echo "the converted host must not write the legacy site.json" >&2; exit 1; }
case "$itc_out" in
*"host: ok (site)"*) ;;
*) echo "converted host summary missing: $itc_out" >&2; exit 1 ;;
esac
_reset6

# E12: provisioning site names default to <hostname>-<slug> for one target and
# <hostname>-<slug>-<target> for several.
_reset6
if ! e12_out="$(var_mode=site var_targets="host 101" var_sites=orga \
  var_pangolin_endpoint=https://p.example \
  var_site_provisioning_key_orga_host=spk-h var_site_provisioning_key_orga_101=spk-1 \
  _run6 2>&1)"; then
  echo "E12 name default run failed: $e12_out" >&2; exit 1
fi
hn="$(hostname 2>/dev/null || printf 'pve')"
python3 - "$s6/snap/host/sites/orga.json" "$hn" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == f"{sys.argv[2]}-orga-host", d
assert d["provisioningKey"] == "spk-h", d
PY
python3 - "$s6/snap/101/sites/orga.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "ct101-orga-101", d
PY

# E13: a single default slug on an already-converted target takes the per-slug
# layout even without a second slug.
_reset6
mkdir -p "$s6/fakeroot/etc/systemd/system"
printf '[Unit]\n' >"$s6/fakeroot/etc/systemd/system/pangolin-site@.service"
if ! e13_out="$(var_mode=site var_target=host var_pangolin_endpoint=https://p.example \
  var_site_id=e13id var_site_secret=e13sec _run6 2>&1)"; then
  echo "E13 converted-host run failed: $e13_out" >&2; exit 1
fi
grep -qx 'MULTI_SITE=1' "$s6/snap/host/flags" ||
  { echo "E13 converted host must set MULTI_SITE=1" >&2; exit 1; }
grep -qx 'SITE_SLUGS=default' "$s6/snap/host/flags" ||
  { echo "E13 converted host must list the default slug" >&2; exit 1; }
[[ -f "$s6/snap/host/sites/default.json" ]] ||
  { echo "E13 converted host must use sites/default.json" >&2; exit 1; }
[[ ! -e "$s6/snap/host/site.json" ]] ||
  { echo "E13 converted host must not write site.json" >&2; exit 1; }
_reset6

# E14: interface existence is checked per generated name, with no empty name,
# before the payload runs.
if ! e14_out="$(var_mode=site var_target=host var_sites="orga orgb" \
  var_site_native=1 var_site_native_main=1 var_pangolin_endpoint=https://p.example \
  var_site_id_orga=i1 var_site_secret_orga=s1 var_site_id_orgb=i2 var_site_secret_orgb=s2 \
  _run6 2>&1)"; then
  echo "E14 interface-check run failed: $e14_out" >&2; exit 1
fi
for name in pangorga pangmorga pangorgb pangmorgb; do
  grep -qx "ip link show $name" "$s6/log" ||
    { echo "E14 missing ip link show $name" >&2; exit 1; }
done
if grep -qE 'ip link show *$' "$s6/log"; then
  echo "E14 must not query an empty interface name" >&2; exit 1
fi
_reset6
e14b_rc=0
e14b_out="$(FAKE_IP_EXISTS=pangorgb var_mode=site var_target=host var_sites="orga orgb" \
  var_site_native=1 var_pangolin_endpoint=https://p.example \
  var_site_id_orga=i1 var_site_secret_orga=s1 var_site_id_orgb=i2 var_site_secret_orgb=s2 \
  _run6 2>&1)" || e14b_rc=$?
unset FAKE_IP_EXISTS
[[ "$e14b_rc" -ne 0 ]] || { echo "E14b an existing interface should fail" >&2; exit 1; }
case "$e14b_out" in
*"Interface pangorgb already exists on target host"*) ;;
*) echo "E14b existing interface message: $e14b_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" ]] || { echo "E14b payload must not run after a collision" >&2; exit 1; }

# E15: a multi-slug run whose extra slug has no credentials and no existing
# config fails before any mutation for that target.
_reset6
e15_rc=0
e15_out="$(var_mode=site var_target=101 var_sites="default orgb" \
  var_pangolin_endpoint=https://p.example \
  var_site_id_default=dsec var_site_secret_default=dsec2 _run6 2>&1)" || e15_rc=$?
[[ "$e15_rc" -ne 0 ]] || { echo "E15 missing extra credentials should fail" >&2; exit 1; }
case "$e15_out" in
*"orgb"*) ;;
*) echo "E15 must name the incomplete slug: $e15_out" >&2; exit 1 ;;
esac
[[ ! -s "$s6/ran" ]] || { echo "E15 payload ran without extra slug credentials" >&2; exit 1; }

# E17: the interactive legacy path must dedupe static site IDs across
# targets. The fake whiptail types the same Site ID for both targets; the
# second target must fail before its answers are pushed or its payload runs.
_reset6
: >"$s6/wlog"
e17_rc=0
e17_out="$(var_mode= var_targets= var_target= var_sites= var_site_ssh_owner= \
  var_pangolin_endpoint=https://p.example FAKE_MODE_OUT=site \
  FAKE_TARGETS_OUT='"host" "101"' _run6 2>&1)" || e17_rc=$?
[[ "$e17_rc" -ne 0 ]] || { echo "E17 duplicate entered site ID must fail the run" >&2; exit 1; }
assert_eq "host" "$(cat "$s6/ran")"
if grep -q 'pct push 101' "$s6/log"; then
  echo "E17 the second target must not install its answers" >&2; exit 1
fi
case "$e17_out" in
*"Duplicate site ID"*) ;;
*) echo "E17 duplicate message missing: $e17_out" >&2; exit 1 ;;
esac
case "$e17_out" in
*"101: failed"*) ;;
*) echo "E17 summary must report 101 failed: $e17_out" >&2; exit 1 ;;
esac
assert_eq "2" "$(grep -c -- '--inputbox Site ID' "$s6/wlog")"
_reset6

# E4: interactive slug prompts reuse already-valid suffixed values and keep the
# shared SSH owner selection.
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_sites var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITEMODE_OUT=multi
  export FAKE_SITES_OUT='"default" "orga" "done"'
  export FAKE_OWNER_OUT=orga
  export PANGOLIN_ROOT="$s6/fakeroot" FAKE_LOG="$s6/log"
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  SITE_PAIR_ID=()
  SITE_PAIR_SECRET=()
  SITE_PAIR_KEY=()
  SITE_PAIR_NAME=()
  TARGETS=(host)
  _target_site_verified() { return 1; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  var_site_id_orga=orgaid var_site_secret_orga=orgasec
  _prompt_inputs host 1 0 || exit 1
  [[ "$var_site_ssh_owner" == orga ]] || exit 1
  [[ "${SITE_PAIR_ID["orga|host"]}" == orgaid ]] || exit 1
  [[ "${SITE_PAIR_SECRET["orga|host"]}" == orgasec ]] || exit 1
  [[ "${SITE_PAIR_ID["default|host"]}" == id ]] || exit 1
  [[ "${SITE_PAIR_SECRET["default|host"]}" == sec ]] || exit 1
  [[ "$(grep -c 'Site credentials:' "$FAKE_WHIPTAIL_LOG")" == 1 ]] || exit 1
  [[ "$(grep -c 'manage multiple site labels' "$FAKE_WHIPTAIL_LOG")" == 1 ]] || exit 1
) >"$s6/e4out" 2>&1; then
  echo "E4 interactive slug flow failed:" >&2
  cat "$s6/e4out" >&2
  exit 1
fi

# The single-site menu path remains the default: choosing "one" prompts nothing
# new and reuses the existing credential prompts exactly once.
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_sites var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITEMODE_OUT=one
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  _target_site_verified() { return 1; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0 || exit 1
  [[ "$var_site_id" == id ]] || exit 1
  [[ -z "${var_site_ssh_owner:-}" ]] || exit 1
  [[ "$(grep -c 'Site SSH owner' "$FAKE_WHIPTAIL_LOG")" == 0 ]] || exit 1
  [[ "$(grep -c 'Site credentials:' "$FAKE_WHIPTAIL_LOG")" == 1 ]] || exit 1
) >"$s6/e4bout" 2>&1; then
  echo "E4b single-site menu flow failed:" >&2
  cat "$s6/e4bout" >&2
  exit 1
fi

# E16: an existing verified site must not hide the one-site/multi-site menu.
# Choosing "multi" opens the label editor; no reuse/replace offer is made for
# the verified target in that flow.
_reset6
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_sites var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/fakeroot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITEMODE_OUT=multi
  export FAKE_SITES_OUT='"default" "orga" "done"'
  export FAKE_OWNER_OUT=orga
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  SITE_PAIR_ID=() SITE_PAIR_SECRET=() SITE_PAIR_KEY=() SITE_PAIR_NAME=()
  TARGETS=(host)
  _target_site_verified() { return 0; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0 || exit 1
  grep -q 'manage multiple site labels' "$s6/wlog" ||
    { echo "E16 verified target must still offer the one/multi menu" >&2; exit 1; }
  grep -q 'Site labels' "$s6/wlog" ||
    { echo "E16 multi choice must open the label editor" >&2; exit 1; }
  if grep -q 'Existing site' "$s6/wlog"; then
    echo "E16 the label editor flow must not show reuse/replace first" >&2; exit 1
  fi
  [[ "$var_sites" == "default orga" ]] ||
    { echo "E16 var_sites wrong: [$var_sites]" >&2; exit 1; }
) >"$s6/e16out" 2>&1; then
  echo "E16 verified target multi-site menu failed:" >&2
  cat "$s6/e16out" >&2
  exit 1
fi

# E16b: with a verified target, choosing "one" keeps the reuse/replace offer.
_reset6
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_sites var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/fakeroot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITEMODE_OUT=one
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  SITE_PAIR_ID=() SITE_PAIR_SECRET=() SITE_PAIR_KEY=() SITE_PAIR_NAME=()
  TARGETS=(host)
  _target_site_verified() { return 0; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0 || exit 1
  [[ "$(grep -c 'manage multiple site labels' "$s6/wlog")" == 1 ]] ||
    { echo "E16b one/multi menu must be offered once" >&2; exit 1; }
  [[ "$(grep -c 'Existing site' "$s6/wlog")" == 1 ]] ||
    { echo "E16b one choice must reach reuse/replace" >&2; exit 1; }
  if grep -q 'Site labels' "$s6/wlog"; then
    echo "E16b one choice must not open the label editor" >&2; exit 1
  fi
) >"$s6/e16bout" 2>&1; then
  echo "E16b verified target one-site flow failed:" >&2
  cat "$s6/e16bout" >&2
  exit 1
fi

# E18: the label editor seeds the labels that already exist on the host: the
# verified default config plus every per-slug config, all starting ON.
_reset6
rm -rf "$s6/proot"
mkdir -p "$s6/proot/etc/pangolin/sites"
printf '{"id":"did","secret":"dsec"}\n' >"$s6/proot/etc/pangolin/site.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/orga.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/orgb.json"
: >"$s6/wlog"
if ! (
  unset var_sites
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/proot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITES_OUT='"default" "orga" "orgb" "done"'
  _target_has_legacy_site() { return 1; }
  _prompt_site_labels host || exit 1
  grep -q 'default Site label default ON orga Site label orga ON orgb Site label orgb ON add' "$s6/wlog" ||
    { echo "E18 host labels must be seeded ON: $(cat "$s6/wlog")" >&2; exit 1; }
  [[ "$var_sites" == "default orga orgb" ]] ||
    { echo "E18 var_sites wrong: [$var_sites]" >&2; exit 1; }
) >"$s6/e18out" 2>&1; then
  echo "E18 label editor host seeding failed:" >&2
  cat "$s6/e18out" >&2
  exit 1
fi

# E18b: the LXC seeding reads the per-slug configs with read-only pct calls.
_reset6
rm -rf "$s6/ctroot"
mkdir -p "$s6/ctroot/101/etc/pangolin/sites"
printf '{}\n' >"$s6/ctroot/101/etc/pangolin/sites/orga.json"
printf '{}\n' >"$s6/ctroot/101/etc/pangolin/sites/orgb.json"
: >"$s6/wlog"
if ! (
  unset var_sites
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/fakeroot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog" FAKE_CT_ROOT="$s6/ctroot"
  export FAKE_SITES_OUT='"orga" "orgb" "done"'
  _prompt_site_labels 101 || exit 1
  grep -q 'orga Site label orga ON orgb Site label orgb ON add' "$s6/wlog" ||
    { echo "E18b LXC labels must be seeded ON: $(cat "$s6/wlog")" >&2; exit 1; }
  if grep -q 'Site label default' "$s6/wlog"; then
    echo "E18b default must not be seeded without a default config" >&2; exit 1
  fi
  [[ "$var_sites" == "orga orgb" ]] ||
    { echo "E18b var_sites wrong: [$var_sites]" >&2; exit 1; }
) >"$s6/e18bout" 2>&1; then
  echo "E18b label editor LXC seeding failed:" >&2
  cat "$s6/e18bout" >&2
  exit 1
fi

# E18c: malformed config filenames are ignored by the seeding.
_reset6
rm -rf "$s6/proot"
mkdir -p "$s6/proot/etc/pangolin/sites"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/orga.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/Bad.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/host.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/a b.json"
printf '{}\n' >"$s6/proot/etc/pangolin/sites/org-.json"
: >"$s6/wlog"
if ! (
  unset var_sites
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/proot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITES_OUT='"orga" "done"'
  _target_has_legacy_site() { return 1; }
  _prompt_site_labels host || exit 1
  grep -q 'orga Site label orga ON add' "$s6/wlog" ||
    { echo "E18c valid label must be seeded: $(cat "$s6/wlog")" >&2; exit 1; }
  for bad in 'Site label Bad' 'Site label host' 'Site label a b' 'Site label org-'; do
    if grep -q "$bad" "$s6/wlog"; then
      echo "E18c malformed label must be ignored: [$bad]" >&2; exit 1
    fi
  done
  [[ "$var_sites" == "orga" ]] ||
    { echo "E18c var_sites wrong: [$var_sites]" >&2; exit 1; }
) >"$s6/e18cout" 2>&1; then
  echo "E18c label editor malformed-name seeding failed:" >&2
  cat "$s6/e18cout" >&2
  exit 1
fi

# E18d: a target with no configs seeds only default.
_reset6
rm -rf "$s6/proot"
mkdir -p "$s6/proot"
: >"$s6/wlog"
if ! (
  unset var_sites
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/proot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITES_OUT='"default" "done"'
  _target_has_legacy_site() { return 1; }
  _prompt_site_labels host || exit 1
  grep -q 'default Site label default ON add' "$s6/wlog" ||
    { echo "E18d fresh target must seed default: $(cat "$s6/wlog")" >&2; exit 1; }
  [[ "$(grep -c 'Site label ' "$s6/wlog")" == 1 ]] ||
    { echo "E18d only default may be seeded" >&2; exit 1; }
  [[ "$var_sites" == "default" ]] ||
    { echo "E18d var_sites wrong: [$var_sites]" >&2; exit 1; }
) >"$s6/e18dout" 2>&1; then
  echo "E18d label editor fresh-target seeding failed:" >&2
  cat "$s6/e18dout" >&2
  exit 1
fi

# E19: choosing the discovered verified label plus a new one sets both in
# var_sites, reuses the verified default without a credentials prompt, and
# never prints the existing config contents.
_reset6
rm -rf "$s6/proot"
mkdir -p "$s6/proot/etc/pangolin"
printf '{"id":"did","secret":"E19-SECRET"}\n' >"$s6/proot/etc/pangolin/site.json"
printf '"default" "add" "done"\n' >"$s6/sites-seq"
printf '"default" "orga" "done"\n' >>"$s6/sites-seq"
rm -f "$s6/sites-seq.n"
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_sites var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/proot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  export FAKE_SITEMODE_OUT=multi FAKE_SITES_SEQ="$s6/sites-seq"
  export FAKE_SLUG_ADD=orga FAKE_OWNER_OUT=orga
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  SITE_PAIR_ID=() SITE_PAIR_SECRET=() SITE_PAIR_KEY=() SITE_PAIR_NAME=()
  TARGETS=(host)
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0 || exit 1
  [[ "$var_sites" == "default orga" ]] ||
    { echo "E19 var_sites wrong: [$var_sites]" >&2; exit 1; }
  grep -q 'default Site label default ON' "$s6/wlog" ||
    { echo "E19 verified default must be seeded ON" >&2; exit 1; }
  [[ "$(grep -c 'New site label' "$s6/wlog")" == 1 ]] ||
    { echo "E19 the editor must accept a new label" >&2; exit 1; }
  if grep -q 'Existing site' "$s6/wlog"; then
    echo "E19 the multi flow must not show reuse/replace" >&2; exit 1
  fi
  [[ "$(grep -c 'Site credentials:' "$s6/wlog")" == 1 ]] ||
    { echo "E19 only the new label may be asked for credentials" >&2; exit 1; }
  [[ "${SITE_PAIR_ID[orga|host]}" == id ]] ||
    { echo "E19 orga credentials missing" >&2; exit 1; }
  [[ -z "${SITE_PAIR_ID[default|host]:-}" ]] ||
    { echo "E19 the verified default must stay unreferenced" >&2; exit 1; }
  if grep -q 'E19-SECRET' "$s6/wlog" "$s6/log"; then
    echo "E19 config content leaked into prompts or logs" >&2; exit 1
  fi
) >"$s6/e19out" 2>&1; then
  echo "E19 existing plus new label flow failed:" >&2
  cat "$s6/e19out" >&2
  exit 1
fi

# E20: an explicit var_sites still bypasses the one/multi menu and keeps the
# verified reuse/replace behavior.
_reset6
: >"$s6/wlog"
if ! (
  unset var_mode var_unattended var_targets var_target var_site_ssh_owner
  unset var_site_id var_site_secret var_site_provisioning_key var_site_name
  unset var_pangolin_endpoint var_site_native var_site_native_main
  unset var_site_interface var_site_interface_main var_reconfigure
  export PATH="$s6/bin:$PATH" PANGOLIN_ROOT="$s6/fakeroot" FAKE_LOG="$s6/log"
  export FAKE_WHIPTAIL_LOG="$s6/wlog"
  SITES_PROMPTED=0 SITE_OWNER_PROMPTED=0 NATIVE_PROMPTED=0
  SITE_PAIR_ID=() SITE_PAIR_SECRET=() SITE_PAIR_KEY=() SITE_PAIR_NAME=()
  TARGETS=(host)
  var_sites="default"
  _target_site_verified() { return 0; }
  _target_has_legacy_site() { return 1; }
  _default_site_name() { printf 'pve\n'; }
  _prompt_inputs host 1 0 || exit 1
  if grep -q 'manage multiple site labels' "$s6/wlog"; then
    echo "E20 explicit var_sites must bypass the one/multi menu" >&2; exit 1
  fi
  if grep -q 'Site labels' "$s6/wlog"; then
    echo "E20 explicit var_sites must bypass the label editor" >&2; exit 1
  fi
  [[ "$(grep -c 'Existing site' "$s6/wlog")" == 1 ]] ||
    { echo "E20 explicit var_sites must keep reuse/replace" >&2; exit 1; }
  [[ "$var_sites" == "default" ]] ||
    { echo "E20 var_sites must be unchanged: [$var_sites]" >&2; exit 1; }
) >"$s6/e20out" 2>&1; then
  echo "E20 explicit var_sites bypass failed:" >&2
  cat "$s6/e20out" >&2
  exit 1
fi

rm -rf "$s6"

echo "Entry tests passed"
echo "Orchestration tests passed"
