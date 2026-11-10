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
  if payload_main "$tmpd2/answers" >/dev/null 2>&1; then
    echo "partial should fail" >&2
    exit 1
  fi
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
  }
  payload_main "$tmpd6/answers" >/dev/null 2>&1
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
  if payload_main "$tmpd3/answers" >/dev/null 2>&1; then
    echo "unprovisioned site should fail" >&2
    exit 1
  fi
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
rm -rf "$dry"

echo "Entry tests passed"
echo "Orchestration tests passed"
