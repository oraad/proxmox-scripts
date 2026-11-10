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
[[ -z "$(ls -A "$dry/tmp")" ]] || { echo "dry runs wrote files" >&2; exit 1; }
[[ ! -e "$dry/curl-ran" ]] || { echo "dry runs used the network" >&2; exit 1; }
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
rm -rf "$dry2"

echo "Entry tests passed"
echo "Orchestration tests passed"
