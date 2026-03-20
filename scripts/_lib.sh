# Shared helper library for gallery-kit scripts.
# Source after _env.sh, then call _init_lib immediately.

_LIB_SOURCE="gallery-kit"
_LIB_VERSION="0.1.0"

_init_lib() {
    _START_TIME=$(python3 -c "import time; print(time.monotonic())")
    _REQUEST_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
    _COMMAND="${_COMMAND:-$(basename "$0" .sh)}"
    _PRETTY=false
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

_parse_flags() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pretty) _PRETTY=true; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    echo "${args[@]:-}"
}

_output() {
    if [[ "$_PRETTY" == true ]]; then
        python3 -m json.tool
    else
        cat
    fi
}

_curl() {
    curl -s -H "X-Request-ID: $_REQUEST_ID" "$@"
}
