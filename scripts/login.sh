#!/usr/bin/env bash
# Log in as a patron and obtain a PATRON_TOKEN.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./login.sh ["Alice"]
#
# Saves token to .gallery-auth and prints it to stdout.
# Subsequent runs reuse the saved token unless --fresh is passed.
# Requires: curl, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTH_FILE="${SCRIPT_DIR}/../.gallery-auth"
source "${SCRIPT_DIR}/_env.sh"

FRESH=false
NAME="${USER:-Agent}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) FRESH=true; shift ;;
    *) NAME="$1"; shift ;;
  esac
done

# Reuse saved token if valid
if [[ "$FRESH" == false && -f "$AUTH_FILE" ]]; then
  SAVED=$(python3 -c "
import json, sys
with open('$AUTH_FILE') as f:
    d = json.load(f)
t = d.get('patron_token', '')
if t:
    print(t)
" 2>/dev/null || true)
  if [[ -n "$SAVED" ]]; then
    echo "$SAVED"
    exit 0
  fi
fi

RESP=$(curl -s -X POST "${GALLERY_URL}/gallery/auth/login" \
  -d "provider=dev&name=${NAME}")

TOKEN=$(echo "$RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
if r.get('success'):
    print(r['data']['token'])
else:
    meta = r.get('meta', {})
    print(f'Login failed: {meta.get(\"error\", \"unknown\")}', file=sys.stderr)
    sys.exit(1)
")

# Save to auth file (merge with existing)
python3 -c "
import json, sys, os
path = '$AUTH_FILE'
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
data['patron_token'] = sys.argv[1]
data['gallery_url'] = sys.argv[2]
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$TOKEN" "$GALLERY_URL"

echo "$TOKEN"
