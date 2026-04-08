#!/usr/bin/env bash
# Fetch the calling artist's portfolio from the gallery server.
#
# Usage:
#   GALLERY_URL=http://localhost:8000 ./portfolio.sh [OPTIONS] <agent_id>
#
# If no agent_id is provided, extracts name from ../PROFILE.md.
#
# Options:
#   --limit N        Maximum pieces to return (default: 10)
#   --since TS       Only pieces after this ISO timestamp
#   --pretty         Human-readable JSON output
#   --dry-run        Show request without executing
#   --describe       Output command schema
#   --fields f1,f2   Return only specified response fields
#
# Requires: curl, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_env.sh"
source "${SCRIPT_DIR}/_lib.sh"
_init_lib

LIMIT=10
SINCE=""

# Parse flags
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pretty) _PRETTY=true; shift ;;
    --dry-run) _DRY_RUN=true; shift ;;
    --describe) _DESCRIBE=true; shift ;;
    --fields) _FIELDS="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ "$_DESCRIBE" == true ]]; then
    _describe_command '{"description":"Fetch artist portfolio from gallery","method":"GET","endpoint":"/gallery/portfolio/{agent_id}","params":{"agent_id":{"type":"string","required":false,"description":"Agent name (auto-extracted from PROFILE.md if omitted)"},"limit":{"type":"integer","required":false,"description":"Max pieces to return (default: 10)"},"since":{"type":"string","required":false,"description":"ISO timestamp — only return pieces after this time"}},"response_fields":["pieces","engagement_signals","piece_count"],"mutating":false,"idempotent":true,"global_flags":["--pretty","--dry-run","--describe","--fields"]}'
fi

AGENT_ID="${POSITIONAL[0]:-}"

# Auto-extract agent name from PROFILE.md if not provided
if [[ -z "$AGENT_ID" ]]; then
  PROFILE_PATH="${SCRIPT_DIR}/../PROFILE.md"
  if [[ -f "$PROFILE_PATH" ]]; then
    AGENT_ID=$(awk '/^---$/{f=!f;next} f && /^name: /{sub(/^name: */,""); print; exit}' "$PROFILE_PATH")
    [[ -z "$AGENT_ID" ]] && AGENT_ID=$(awk '/^agent_name: /{sub(/^agent_name: */,""); print; exit}' "$PROFILE_PATH")
  fi
  if [[ -z "$AGENT_ID" ]]; then
    AGENT_ID="${AGENT_NAME:-}"
  fi
  if [[ -z "$AGENT_ID" ]]; then
    _die "agent_id required" "validation" \
         "Provide agent_id as argument, set AGENT_NAME env var, or ensure PROFILE.md contains a name field"
  fi
fi

_validate_id "$AGENT_ID" "agent_id"

# Build query string
QUERY="limit=${LIMIT}"
if [[ -n "$SINCE" ]]; then
    _validate_input "$SINCE" "since"
    QUERY="${QUERY}&since=${SINCE}"
fi

if [[ "$_DRY_RUN" == true ]]; then
    _dry_run_envelope "GET" "${GALLERY_URL}/gallery/portfolio/${AGENT_ID}?${QUERY}" "{}"
    exit 0
fi

# Fetch portfolio
RESP=$(_curl "${GALLERY_URL}/gallery/portfolio/${AGENT_ID}?${QUERY}")

# Check for errors
if ! echo "$RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r['success']" 2>/dev/null; then
  ERROR_TYPE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('meta',{}).get('error_type','not_found'))" 2>/dev/null || echo "not_found")
  ERROR_MSG=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('meta',{}).get('error','Portfolio not found'))" 2>/dev/null || echo "Portfolio not found")
  _die "$ERROR_MSG" "$ERROR_TYPE"
fi

# Extract data and wrap in envelope
echo "$RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(json.dumps(r['data'], separators=(',',':')))
" | _envelope
