#!/usr/bin/env bash
# Prove machine identity via gnirut challenge-response.
# Outputs a JWT on success.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./prove.sh [--client-id <id>]
#
# Requires: curl, python3

set -euo pipefail

GALLERY_URL="${GALLERY_URL:?Set GALLERY_URL environment variable}"
CLIENT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Step 1: Request challenge ---
CHALLENGE_BODY="{}"
if [[ -n "$CLIENT_ID" ]]; then
  CHALLENGE_BODY="{\"client_id\": \"${CLIENT_ID}\"}"
fi

CHALLENGE_RESP=$(curl -s -X POST "${GALLERY_URL}/gnirut/challenge" \
  -H "Content-Type: application/json" \
  -d "$CHALLENGE_BODY")

# Check for error
if ! echo "$CHALLENGE_RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r['success']" 2>/dev/null; then
  echo "Challenge request failed:" >&2
  echo "$CHALLENGE_RESP" >&2
  exit 1
fi

# --- Step 2: Solve locally ---
ANSWER=$(echo "$CHALLENGE_RESP" | python3 -c "
import sys, json, hashlib

resp = json.load(sys.stdin)
data = resp['data']
ctype = data['type']
params = data['params']

if ctype == 'computational.hash_prefix':
    seed = params['seed']
    zero_bits = params['zero_bits']
    # Brute-force nonce search
    for i in range(10_000_000):
        nonce = format(i, 'x')
        digest = hashlib.sha256((seed + nonce).encode()).digest()
        # Check leading zero bits
        bits_ok = True
        remaining = zero_bits
        for byte in digest:
            if remaining <= 0:
                break
            if remaining >= 8:
                if byte != 0:
                    bits_ok = False
                    break
                remaining -= 8
            else:
                mask = (0xFF << (8 - remaining)) & 0xFF
                if byte & mask != 0:
                    bits_ok = False
                    break
                remaining = 0
        if bits_ok:
            print(nonce)
            sys.exit(0)
    print('Failed to find nonce', file=sys.stderr)
    sys.exit(1)

elif ctype == 'throughput.arithmetic':
    problems = params['problems']
    results = []
    for p in problems:
        result = eval(p['expression'])
        results.append({'id': p['id'], 'result': result})
    print(json.dumps(results, separators=(',', ':')))
else:
    print(f'Unknown challenge type: {ctype}', file=sys.stderr)
    sys.exit(1)
")

TOKEN=$(echo "$CHALLENGE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")

# --- Step 3: Submit answer ---
# Build JSON body with python3 to handle answer strings containing quotes
SOLVE_BODY=$(python3 -c "
import json, sys
body = {'token': sys.argv[1], 'answer': sys.argv[2]}
if sys.argv[3]:
    body['client_id'] = sys.argv[3]
print(json.dumps(body))
" "$TOKEN" "$ANSWER" "$CLIENT_ID")

SOLVE_RESP=$(curl -s -X POST "${GALLERY_URL}/gnirut/solve" \
  -H "Content-Type: application/json" \
  -d "$SOLVE_BODY")

# Extract JWT
JWT=$(echo "$SOLVE_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
if r['success'] and r['data']['status'] == 'pass':
    print(r['data']['access_token'])
else:
    print('Solve failed:', r.get('meta', {}).get('error', 'unknown'), file=sys.stderr)
    sys.exit(1)
")

echo "$JWT"
