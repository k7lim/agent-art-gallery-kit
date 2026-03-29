# Shared helper library for gallery-kit scripts.
# Source after _env.sh, then call _init_lib immediately.

_LIB_SOURCE="gallery-kit"
_LIB_VERSION="0.1.0"

_init_lib() {
    _START_TIME=$(python3 -c "import time; print(time.monotonic())")
    _REQUEST_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
    _COMMAND="${_COMMAND:-$(basename "$0" .sh)}"
    _PRETTY=false
    _DRY_RUN=false
    _DESCRIBE=false
    _FIELDS=""
}

_envelope() {
    local command="${1:-$_COMMAND}"
    local extra_meta="${2:-"{}"}"
    _E_EXTRA="$extra_meta" python3 -c "
import json, sys, time, os
data = json.load(sys.stdin)
meta = {'source': '$_LIB_SOURCE', 'command': '$command',
        'request_id': '$_REQUEST_ID', 'version': '$_LIB_VERSION',
        'latency_ms': max(0, int((time.monotonic() - $_START_TIME) * 1000))}
extra = json.loads(os.environ['_E_EXTRA'])
meta.update(extra)
print(json.dumps({'success': True, 'data': data, 'meta': meta}, separators=(',',':')))
" | _output
}

_error_envelope() {
    local error="$1" error_type="$2" retry_guidance="${3:-}" command="${4:-$_COMMAND}"
    _E_ERROR="$error" _E_TYPE="$error_type" _E_GUIDANCE="$retry_guidance" python3 -c "
import json, time, os
meta = {'source': '$_LIB_SOURCE', 'command': '$command',
        'request_id': '$_REQUEST_ID', 'version': '$_LIB_VERSION',
        'latency_ms': max(0, int((time.monotonic() - $_START_TIME) * 1000)),
        'error': os.environ['_E_ERROR'], 'error_type': os.environ['_E_TYPE'],
        'retry_guidance': os.environ['_E_GUIDANCE']}
print(json.dumps({'success': False, 'data': None, 'meta': meta}, separators=(',',':')))
" | _output
}

_log() {
    local level="$1" msg="$2"
    _L_MSG="$msg" python3 -c "
import json, time, os
print(json.dumps({'ts': time.time(), 'level': '$level', 'msg': os.environ['_L_MSG'],
    'request_id': '$_REQUEST_ID', 'command': '$_COMMAND',
    'latency_ms': max(0, int((time.monotonic() - $_START_TIME) * 1000))}), file=__import__('sys').stderr)
"
}

_exit_code() {
    local error_type="$1"
    case "$error_type" in
        validation|validation_error|field_required|field_too_long|tag_count_invalid|\
        unsupported_format|format_mismatch|file_too_large|dimensions_exceeded|\
        duration_exceeded|corrupt_file|invalid_category) echo 1 ;;
        not_found) echo 2 ;;
        invalid_token|token_expired|invalid_patron_token|invalid_gnirut_token|\
        forbidden|auth_error) echo 3 ;;
        conflict|replay) echo 4 ;;
        *) echo 5 ;;
    esac
}

_die() {
    local error="$1" error_type="$2" retry_guidance="${3:-}"
    _error_envelope "$error" "$error_type" "$retry_guidance"
    _log "error" "$error"
    exit $(_exit_code "$error_type")
}

_validate_input() {
    local value="$1" label="${2:-input}"
    # Reject dangerous control chars (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F); allow tab/LF/CR
    if printf '%s' "$value" | LC_ALL=C tr -d '[:print:]\011\012\015' | grep -q '.'; then
        _die "Invalid ${label}: contains control characters" "validation" \
             "Remove non-printable characters from ${label}"
    fi
    # Reject path traversal
    if [[ "$value" == *".."* ]]; then
        _die "Invalid ${label}: path traversal not allowed" "validation" \
             "Remove '..' from ${label}"
    fi
    # Reject embedded query/fragment
    if [[ "$value" == *"?"* || "$value" == *"#"* ]]; then
        _die "Invalid ${label}: embedded query params not allowed" "validation" \
             "Remove '?' and '#' from ${label}"
    fi
    # Reject percent-encoding (encode at HTTP layer only)
    if [[ "$value" == *"%"* ]]; then
        _die "Invalid ${label}: percent-encoding not allowed" "validation" \
             "Pass raw values; URL encoding is handled automatically"
    fi
}

_validate_id() {
    local value="$1" label="${2:-input}"
    # Reject control characters (below ASCII 0x20)
    if printf '%s' "$value" | LC_ALL=C tr -d '[:print:]' | grep -q '.'; then
        _die "Invalid ${label}: contains control characters" "validation" \
             "Remove non-printable characters from ${label}"
    fi
    # Reject path traversal
    if [[ "$value" == *".."* || "$value" == *"/"* ]]; then
        _die "Invalid ${label}: path traversal not allowed" "validation" \
             "Remove '..' and '/' from ${label}"
    fi
    # Reject embedded query params (? and #)
    if [[ "$value" == *"?"* || "$value" == *"#"* ]]; then
        _die "Invalid ${label}: embedded query params not allowed" "validation" \
             "Remove '?' and '#' from ${label}"
    fi
    # Reject percent-encoding (encode at HTTP layer only)
    if [[ "$value" == *"%"* ]]; then
        _die "Invalid ${label}: percent-encoding not allowed" "validation" \
             "Pass raw values; URL encoding is handled automatically"
    fi
}

_parse_flags() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pretty) _PRETTY=true; shift ;;
            --dry-run) _DRY_RUN=true; shift ;;
            --describe) _DESCRIBE=true; shift ;;
            --fields) _FIELDS="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    echo "${args[@]:-}"
}

_describe_command() {
    local schema="$1"
    echo "$schema" | _envelope "$_COMMAND" '{"describe":true}'
    exit 0
}

_dry_run_envelope() {
    local method="$1" url="$2" payload="${3:-"{}"}"
    _DR_METHOD="$method" _DR_URL="$url" _DR_PAYLOAD="$payload" python3 -c "
import json, os
data = {'dry_run': True, 'method': os.environ['_DR_METHOD'],
        'url': os.environ['_DR_URL'], 'payload': json.loads(os.environ['_DR_PAYLOAD'])}
print(json.dumps(data, separators=(',',':')))
" | _envelope "$_COMMAND" '{"dry_run":true}'
}

_output() {
    if [[ -n "$_FIELDS" ]]; then
        _F_FIELDS="$_FIELDS" _F_PRETTY="$_PRETTY" python3 -c "
import json, sys, os
obj = json.load(sys.stdin)
fields = set(os.environ['_F_FIELDS'].split(','))
if obj.get('data') and isinstance(obj['data'], dict):
    obj['data'] = {k: v for k, v in obj['data'].items() if k in fields}
elif obj.get('data') and isinstance(obj['data'], list):
    obj['data'] = [{k: v for k, v in item.items() if k in fields} for item in obj['data']]
pretty = os.environ.get('_F_PRETTY') == 'true'
print(json.dumps(obj, indent=2 if pretty else None,
    separators=None if pretty else (',',':')))
"
    elif [[ "$_PRETTY" == true ]]; then
        python3 -m json.tool
    else
        cat
    fi
}

_curl() {
    curl -s -H "X-Request-ID: $_REQUEST_ID" "$@"
}
