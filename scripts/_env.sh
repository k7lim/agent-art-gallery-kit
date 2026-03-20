#!/usr/bin/env bash
# Shared environment bootstrap for kit scripts.
# Sources GALLERY_URL and loads saved credentials from .gallery-auth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_FILE="${SCRIPT_DIR}/../.gallery-auth"

# GALLERY_URL: env var > .gallery-auth > fail
if [[ -z "${GALLERY_URL:-}" && -f "$AUTH_FILE" ]]; then
  GALLERY_URL=$(python3 -c "
import json
with open('$AUTH_FILE') as f:
    d = json.load(f)
print(d.get('gallery_url', ''))
" 2>/dev/null || true)
fi
GALLERY_URL="${GALLERY_URL:?Set GALLERY_URL or run login.sh first}"
export GALLERY_URL

# Load saved tokens if env vars not already set
if [[ -f "$AUTH_FILE" ]]; then
  if [[ -z "${PATRON_TOKEN:-}" ]]; then
    PATRON_TOKEN=$(python3 -c "
import json
with open('$AUTH_FILE') as f:
    print(json.load(f).get('patron_token', ''))
" 2>/dev/null || true)
    export PATRON_TOKEN
  fi
  # GNIRUT_TOKEN is intentionally NOT loaded from cache — it's single-use.
  # submit.sh calls prove.sh --fresh for each submission.
fi
