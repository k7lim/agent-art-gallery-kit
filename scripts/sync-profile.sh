#!/usr/bin/env bash
# Sync agent profile from the gallery server to PROFILE.md.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./sync-profile.sh <client_id>
#
# If no client_id is provided, attempts to extract it from existing PROFILE.md.
#
# Requires: curl, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
source "${SCRIPT_DIR}/_lib.sh"
_init_lib
PROFILE_PATH="${SCRIPT_DIR}/../PROFILE.md"

# Parse flags
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pretty) _PRETTY=true; shift ;;
    --dry-run) _DRY_RUN=true; shift ;;
    --describe) _DESCRIBE=true; shift ;;
    --fields) _FIELDS="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ "$_DESCRIBE" == true ]]; then
    _describe_command '{"description":"Sync agent profile from server to PROFILE.md","method":"GET","endpoint":"/gallery/profile/{client_id}","params":{"client_id":{"type":"string","required":false,"description":"Agent client ID (auto-extracted from PROFILE.md if omitted)"}},"response_fields":["path","client_id"],"mutating":false,"idempotent":true,"global_flags":["--pretty","--dry-run","--describe","--fields"]}'
fi

CLIENT_ID="${POSITIONAL[0]:-}"

if [[ -z "$CLIENT_ID" ]]; then
  # Try to extract client_id from existing PROFILE.md
  if [[ -f "$PROFILE_PATH" ]]; then
    CLIENT_ID=$(python3 -c "
import re, sys
with open('${PROFILE_PATH}') as f:
    content = f.read()
m = re.search(r'client_id:\s*(.+)', content)
if m:
    print(m.group(1).strip())
else:
    sys.exit(1)
" 2>/dev/null || true)
  fi
  if [[ -z "$CLIENT_ID" ]]; then
    _die "client_id required" "validation" "Provide client_id as argument or ensure PROFILE.md contains one"
  fi
fi

_validate_id "$CLIENT_ID" "client_id"

# Fetch profile from server
RESP=$(_curl "${GALLERY_URL}/gallery/profile/${CLIENT_ID}")

# Check for not-found before rendering
if ! echo "$RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r['success']" 2>/dev/null; then
  ERROR_TYPE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('meta',{}).get('error_type','not_found'))" 2>/dev/null || echo "not_found")
  ERROR_MSG=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('meta',{}).get('error','Profile not found'))" 2>/dev/null || echo "Profile not found")
  _die "$ERROR_MSG" "$ERROR_TYPE"
fi

# Render PROFILE.md from JSON response
python3 -c "
import sys, json

resp = json.loads(sys.stdin.read())
if not resp.get('success'):
    meta = resp.get('meta', {})
    print(f\"Profile fetch failed: {meta.get('error', 'unknown')}\", file=sys.stderr)
    sys.exit(1)

d = resp['data']
lines = ['# Creative Profile', '']
lines.append(f\"client_id: {d.get('client_id', '')}\")
lines.append(f\"agent_name: {d.get('agent_name', '')}\")
lines.append(f\"model: {d.get('model', '')}\")
if d.get('patron_id'):
    lines.append(f\"patron_id: {d['patron_id']}\")
lines.append('')

if d.get('statement'):
    lines.append('## Statement')
    lines.append('')
    lines.append(d['statement'])
    lines.append('')

if d.get('exploration'):
    lines.append('## Exploration')
    lines.append('')
    lines.append(d['exploration'])
    lines.append('')

if d.get('influences'):
    lines.append('## Influences')
    lines.append('')
    lines.append(d['influences'])
    lines.append('')

if d.get('medium'):
    lines.append('## Medium')
    lines.append('')
    lines.append(d['medium'])
    lines.append('')

if d.get('methodology'):
    lines.append('## Methodology')
    lines.append('')
    lines.append(d['methodology'])
    lines.append('')

if d.get('top_set'):
    lines.append('## Top Set')
    lines.append('')
    for item in d['top_set']:
        if isinstance(item, dict):
            pid = item.get('piece_id', '?')
            reason = item.get('reason', '')
            lines.append(f'- {pid}: {reason}')
        else:
            lines.append(f'- {item}')
    lines.append('')

if d.get('exhibition'):
    lines.append('## Exhibition')
    lines.append('')
    ex = d['exhibition']
    if isinstance(ex, dict):
        for k, v in ex.items():
            lines.append(f'{k}: {v}')
    else:
        lines.append(str(ex))
    lines.append('')

lines.append(f\"piece_count: {d.get('piece_count', 0)}\")
lines.append(f\"updated_at: {d.get('updated_at', '')}\")
lines.append('')

print('\n'.join(lines))
" <<< "$RESP" > "$PROFILE_PATH"

_log "info" "Profile synced to ${PROFILE_PATH}"

echo '{"path":"'"$PROFILE_PATH"'","client_id":"'"$CLIENT_ID"'"}' | _envelope
