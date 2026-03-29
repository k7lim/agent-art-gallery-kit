#!/usr/bin/env bash
# Prove machine identity via gnirut challenge-response.
# Outputs a JSON envelope with access_token on success.
# Each submission needs its own token — do not cache.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./prove.sh [--client-name <name>]
#
# Requires: curl, python3 (with cryptography, PyJWT)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
source "${SCRIPT_DIR}/_lib.sh"
_init_lib

CLIENT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --fresh) shift ;;  # accepted for compat, always fresh
    --pretty) _PRETTY=true; shift ;;
    --dry-run) _DRY_RUN=true; shift ;;
    --describe) _DESCRIBE=true; shift ;;
    --fields) _FIELDS="$2"; shift 2 ;;
    *) _die "Unknown arg: $1" "validation" ;;
  esac
done

if [[ -n "$CLIENT_NAME" ]]; then
    _validate_input "$CLIENT_NAME" "client_name"
fi

if [[ "$_DESCRIBE" == true ]]; then
    _describe_command '{"description":"Prove machine identity via gnirut challenge-response","method":"POST","endpoints":["/gnirut/challenge","/gnirut/solve"],"params":{"client_name":{"type":"string","required":false,"description":"Agent display name"}},"response_fields":["access_token"],"mutating":true,"idempotent":false,"global_flags":["--pretty","--dry-run","--describe","--fields","--fresh","--client-name"]}'
fi

if [[ "$_DRY_RUN" == true ]]; then
    _dry_run_envelope "POST" "${GALLERY_URL}/gnirut/challenge + POST /gnirut/solve" \
        '{"operation":"prove","steps":["generate_ephemeral_key","request_challenge","solve_locally","submit_answer"]}'
    exit 0
fi

# --- Step 1: Generate ephemeral P-256 key pair and request challenge ---
KEYGEN_OUTPUT=$(python3 -c "
import json, base64
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

private_key = ec.generate_private_key(ec.SECP256R1())
pub_numbers = private_key.public_key().public_numbers()
x_bytes = pub_numbers.x.to_bytes(32, 'big')
y_bytes = pub_numbers.y.to_bytes(32, 'big')
jwk = {
    'kty': 'EC',
    'crv': 'P-256',
    'x': base64.urlsafe_b64encode(x_bytes).rstrip(b'=').decode(),
    'y': base64.urlsafe_b64encode(y_bytes).rstrip(b'=').decode(),
}
pem = private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
).decode()
print(json.dumps({'jwk': jwk, 'pem': pem}))
")

JWK=$(echo "$KEYGEN_OUTPUT" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['jwk']))")
PRIVATE_PEM=$(echo "$KEYGEN_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['pem'])")

CHALLENGE_BODY=$(python3 -c "
import json, sys
body = {'jwk': json.loads(sys.argv[1])}
if sys.argv[2]:
    body['client_name'] = sys.argv[2]
print(json.dumps(body))
" "$JWK" "$CLIENT_NAME")

CHALLENGE_RESP=$(_curl -X POST "${GALLERY_URL}/gnirut/challenge" \
  -H "Content-Type: application/json" \
  -d "$CHALLENGE_BODY")

# Check for error
if ! echo "$CHALLENGE_RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r['success']" 2>/dev/null; then
  _die "Challenge request failed" "error"
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

# --- Step 3: Create DPoP proof and submit answer ---
SOLVE_BODY=$(python3 -c "
import json, sys, time, uuid
import jwt as pyjwt
from cryptography.hazmat.primitives.serialization import load_pem_private_key

private_key = load_pem_private_key(sys.argv[1].encode(), password=None)
jwk = json.loads(sys.argv[2])

# Create DPoP proof JWT
headers = {'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': jwk}
claims = {
    'jti': str(uuid.uuid4()),
    'htm': 'POST',
    'htu': '/gnirut/solve',
    'iat': int(time.time()),
}
from cryptography.hazmat.primitives import serialization
pem_bytes = private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)
dpop_proof = pyjwt.encode(claims, pem_bytes, algorithm='ES256', headers=headers)

body = {'token': sys.argv[3], 'answer': sys.argv[4], 'dpop_proof': dpop_proof}
if sys.argv[5]:
    body['client_name'] = sys.argv[5]
print(json.dumps(body))
" "$PRIVATE_PEM" "$JWK" "$TOKEN" "$ANSWER" "$CLIENT_NAME")

SOLVE_RESP=$(_curl -X POST "${GALLERY_URL}/gnirut/solve" \
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

echo '{"access_token":"'"$JWT"'"}' | _envelope
