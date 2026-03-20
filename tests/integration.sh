#!/usr/bin/env bash
# Integration tests for agent-art-gallery-kit scripts.
# Runs prove.sh, submit.sh, and sync-profile.sh against a live server.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./tests/integration.sh
#
# Prerequisites:
#   - A running gallery server at GALLERY_URL
#   - curl, python3
#
# The test obtains its own patron token via the dev login endpoint.

set -uo pipefail

GALLERY_URL="${GALLERY_URL:?Set GALLERY_URL environment variable}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="${SCRIPT_DIR}/.."

# ── Helpers ──────────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
COLLECTED_RESPONSES=()

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ✓ $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  ✗ $1" >&2
  if [[ -n "${2:-}" ]]; then
    echo "    $2" >&2
  fi
}

header() {
  echo ""
  echo "── $1 ──"
}

assert_not_empty() {
  local label="$1" value="$2"
  if [[ -n "$value" ]]; then
    pass "$label is non-empty"
  else
    fail "$label is empty"
  fi
}

assert_envelope() {
  local output="$1" label="$2"
  echo "$output" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert 'success' in r, 'missing success'
assert 'data' in r, 'missing data'
assert 'meta' in r, 'missing meta'
m = r['meta']
assert 'request_id' in m, 'missing meta.request_id'
assert 'latency_ms' in m, 'missing meta.latency_ms'
assert 'source' in m, 'missing meta.source'
assert 'command' in m, 'missing meta.command'
" && pass "$label: valid envelope" || fail "$label: invalid envelope"
}

assert_success() {
  local output="$1" label="$2"
  echo "$output" | python3 -c "
import sys, json; r = json.load(sys.stdin); assert r['success'] == True
" && pass "$label: success=true" || fail "$label: success!=true"
}

assert_field() {
  local output="$1" jq_path="$2" expected="$3" label="$4"
  echo "$output" | python3 -c "
import sys, json
r = json.load(sys.stdin)
val = r
for key in '$jq_path'.split('.'):
    if key.isdigit(): val = val[int(key)]
    else: val = val[key]
assert str(val) == '$expected', f'expected $expected, got {val}'
" && pass "$label" || fail "$label"
}

assert_exit_code() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] && pass "$label: exit=$expected" || fail "$label: exit=$actual, want $expected"
}

collect_response() {
  COLLECTED_RESPONSES+=("$1|$2")
}

make_test_png() {
  python3 -c "
import struct, zlib
# Minimal 1x1 red PNG
sig = b'\x89PNG\r\n\x1a\n'
def chunk(ctype, data):
    c = ctype + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
raw = zlib.compress(b'\x00\xff\x00\x00')
idat = chunk(b'IDAT', raw)
iend = chunk(b'IEND', b'')
import sys; sys.stdout.buffer.write(sig + ihdr + idat + iend)
" > "$1"
}

# ── 1. Health check ─────────────────────────────────────────────────────────

header "Health check"

HEALTH_RESP=$(curl -sf "${GALLERY_URL}/gnirut/categories" 2>&1) || true
collect_response "health" "$HEALTH_RESP"

if [[ -n "$HEALTH_RESP" ]]; then
  assert_success "$HEALTH_RESP" "GET /gnirut/categories"
else
  fail "GET /gnirut/categories — server unreachable at ${GALLERY_URL}"
  echo ""
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  exit 1
fi

# ── 2. Patron login ─────────────────────────────────────────────────────────

header "Patron login"

LOGIN_RESP=$(curl -s -X POST "${GALLERY_URL}/gallery/auth/login?provider=dev&name=integration-test")
collect_response "login" "$LOGIN_RESP"

assert_success "$LOGIN_RESP" "POST /gallery/auth/login"

PATRON_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r.get('data', {}).get('token', ''))
" 2>/dev/null || echo "")

assert_not_empty "PATRON_TOKEN" "$PATRON_TOKEN"

if [[ -z "$PATRON_TOKEN" ]]; then
  fail "Cannot continue without PATRON_TOKEN"
  echo ""
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  exit 1
fi

# ── 3. prove.sh ─────────────────────────────────────────────────────────────

header "prove.sh"

PROVE_OUTPUT=$(GALLERY_URL="$GALLERY_URL" bash "${KIT_DIR}/scripts/prove.sh" 2>/dev/null) || true

assert_not_empty "PROVE_OUTPUT" "$PROVE_OUTPUT"
assert_envelope "$PROVE_OUTPUT" "prove"
assert_success "$PROVE_OUTPUT" "prove"

JWT=$(echo "$PROVE_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['access_token'])" 2>/dev/null || echo "")
assert_not_empty "prove access_token" "$JWT"

# Verify JWT has 3 dot-separated segments
SEGMENTS=$(echo "$JWT" | tr '.' '\n' | wc -l)
if [[ "$SEGMENTS" -eq 3 ]]; then
  pass "JWT has 3 segments"
else
  fail "JWT has $SEGMENTS segments"
fi

collect_response "prove" "$PROVE_OUTPUT"

if [[ -z "$JWT" ]]; then
  fail "Cannot continue without GNIRUT_TOKEN"
  echo ""
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  exit 1
fi

# ── 4. submit.sh ────────────────────────────────────────────────────────────

header "submit.sh"

TEST_PNG=$(mktemp /tmp/integration-test-XXXXXX.png)
PROFILE_BACKUP=""
cleanup() {
  rm -f "$TEST_PNG"
  if [[ -n "${PROFILE_BACKUP:-}" && -f "$PROFILE_BACKUP" ]]; then
    mv "$PROFILE_BACKUP" "${KIT_DIR}/PROFILE.md"
  fi
}
trap cleanup EXIT

make_test_png "$TEST_PNG"

if [[ -f "$TEST_PNG" && -s "$TEST_PNG" ]]; then
  pass "Generated test PNG"
else
  fail "Failed to generate test PNG"
  echo ""
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  exit 1
fi

SUBMIT_OUTPUT=$(
  GALLERY_URL="$GALLERY_URL" \
  PATRON_TOKEN="$PATRON_TOKEN" \
  AGENT_NAME="integration-test-agent" \
  AGENT_MODEL="test" \
  CO_AUTHOR="integration-test" \
  bash "${KIT_DIR}/scripts/submit.sh" "$TEST_PNG" "Integration test submission" "test,integration" 2>/dev/null
) || true

assert_not_empty "submit.sh output" "$SUBMIT_OUTPUT"
assert_envelope "$SUBMIT_OUTPUT" "submit"
assert_success "$SUBMIT_OUTPUT" "submit"

PIECE_ID=$(echo "$SUBMIT_OUTPUT" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r.get('data', {}).get('piece_id', r.get('data', {}).get('id', '')))
" 2>/dev/null || echo "")

assert_not_empty "piece_id from submit" "$PIECE_ID"
collect_response "submit" "$SUBMIT_OUTPUT"

# ── 5. Piece lookup ─────────────────────────────────────────────────────────

header "Piece lookup"

if [[ -n "$PIECE_ID" ]]; then
  PIECE_RESP=$(curl -s "${GALLERY_URL}/gallery/pieces/${PIECE_ID}")
  collect_response "piece" "$PIECE_RESP"

  assert_success "$PIECE_RESP" "GET /gallery/pieces/{piece_id}"
  assert_envelope "$PIECE_RESP" "GET /gallery/pieces/{piece_id}"
else
  fail "Skipping piece lookup — no piece_id"
fi

# ── 6. sync-profile.sh ──────────────────────────────────────────────────────

header "sync-profile.sh"

# Extract key_thumbprint from piece lookup (serves as the client identity)
CLIENT_ID=""
if [[ -n "${PIECE_RESP:-}" ]]; then
  CLIENT_ID=$(echo "$PIECE_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
d = r.get('data', {})
ai = d.get('agent_identity', {})
print(ai.get('key_thumbprint', ''))
" 2>/dev/null || echo "")
fi

if [[ -n "$CLIENT_ID" ]]; then
  # Create a profile first so sync-profile.sh has something to fetch.
  # POST /gallery/profile requires a fresh gnirut_token + patron_token (documented in SKILL.md).
  GNIRUT_TOKEN_2_OUTPUT=$(GALLERY_URL="$GALLERY_URL" bash "${KIT_DIR}/scripts/prove.sh" 2>/dev/null) || true
  GNIRUT_TOKEN_2=$(echo "$GNIRUT_TOKEN_2_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['access_token'])" 2>/dev/null || echo "")
  if [[ -z "$GNIRUT_TOKEN_2" ]]; then
    fail "Could not obtain second gnirut token for profile creation"
  fi
  PROFILE_CREATE_RESP=$(curl -s -X POST "${GALLERY_URL}/gallery/profile" \
    -F "gnirut_token=${GNIRUT_TOKEN_2}" \
    -F "patron_token=${PATRON_TOKEN}" \
    -F "statement=Integration test profile" \
    -F "agent_name=integration-test-agent")
  collect_response "profile_create" "$PROFILE_CREATE_RESP"
  assert_success "$PROFILE_CREATE_RESP" "POST /gallery/profile (create)"

  # The profile's key_thumbprint may differ from the piece's (ephemeral keys).
  # Use the one from profile creation for sync.
  PROFILE_CLIENT_ID=$(echo "$PROFILE_CREATE_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r.get('data', {}).get('key_thumbprint', ''))
" 2>/dev/null || echo "")

  if [[ -z "$PROFILE_CLIENT_ID" ]]; then
    PROFILE_CLIENT_ID="$CLIENT_ID"
  fi

  # sync-profile.sh writes to PROFILE.md relative to scripts/ dir.
  # Back up original PROFILE.md if it exists, restore after test.
  PROFILE_PATH="${KIT_DIR}/PROFILE.md"
  if [[ -f "$PROFILE_PATH" ]]; then
    PROFILE_BACKUP=$(mktemp /tmp/profile-backup-XXXXXX.md)
    cp "$PROFILE_PATH" "$PROFILE_BACKUP"
  fi

  SYNC_OUTPUT=$(GALLERY_URL="$GALLERY_URL" bash "${KIT_DIR}/scripts/sync-profile.sh" "$PROFILE_CLIENT_ID" 2>/dev/null) || true

  assert_not_empty "sync-profile.sh output" "$SYNC_OUTPUT"
  assert_envelope "$SYNC_OUTPUT" "sync-profile"
  assert_success "$SYNC_OUTPUT" "sync-profile"
  collect_response "sync-profile" "$SYNC_OUTPUT"

  if [[ -f "$PROFILE_PATH" && -s "$PROFILE_PATH" ]]; then
    pass "sync-profile.sh wrote non-empty PROFILE.md"
  else
    fail "sync-profile.sh did not produce PROFILE.md"
  fi

  # Check it contains expected header
  if grep -q "# Creative Profile" "$PROFILE_PATH" 2>/dev/null; then
    pass "PROFILE.md contains '# Creative Profile' header"
  else
    fail "PROFILE.md missing expected header"
  fi

  # Cleanup handled by EXIT trap
else
  fail "Skipping sync-profile.sh — no client_id (key_thumbprint) found in piece lookup"
fi

# ── 7. Exit code consistency ─────────────────────────────────────────────────

header "exit code consistency"

source "${KIT_DIR}/scripts/_lib.sh"
_init_lib
[[ $(_exit_code "validation") == "1" ]] && pass "validation=1" || fail "validation!=1"
[[ $(_exit_code "not_found") == "2" ]] && pass "not_found=2" || fail "not_found!=2"
[[ $(_exit_code "auth_error") == "3" ]] && pass "auth_error=3" || fail "auth_error!=3"
[[ $(_exit_code "conflict") == "4" ]] && pass "conflict=4" || fail "conflict!=4"
[[ $(_exit_code "something_else") == "5" ]] && pass "unknown=5" || fail "unknown!=5"

# ── 8. Envelope check on all collected responses ────────────────────────────

header "Envelope check (all collected responses)"

for entry in "${COLLECTED_RESPONSES[@]}"; do
  label="${entry%%|*}"
  body="${entry#*|}"
  if [[ -n "$body" ]]; then
    assert_envelope "$body" "response:${label}"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "════════════════════════════════════════"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
