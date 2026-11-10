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
grep -q 'PANGOLIN_CLIENT_ID=cid' "$dir/client.env" || { echo "client answers" >&2; exit 1; }
[[ "$(stat -c '%a' "$dir/client.env")" == "600" ]] || { echo "client env mode" >&2; exit 1; }
rm -rf "$dir"

echo "Entry tests passed"
