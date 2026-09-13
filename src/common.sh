#!/usr/bin/env bash
# Shared helpers: logging, HTTP with retries/rate-limit handling.

if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log()  { printf '%s[info]%s %s\n'  "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n'  "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }

USER_AGENT="${USER_AGENT:-LeadFinder/1.0 (local research tool)}"
HTTP_MAX_RETRIES="${HTTP_MAX_RETRIES:-4}"

# http_request OUTFILE curl-args...
# Retries on network errors, 429 and 5xx with exponential backoff.
# Prints the final HTTP status code on stdout. Returns 0 on 2xx.
http_request() {
  local out="$1"; shift
  local attempt=1 delay=2 code
  while :; do
    code=$(curl -sS -A "$USER_AGENT" --connect-timeout 10 --max-time 60 \
                -o "$out" -w '%{http_code}' "$@" 2>/dev/null) || code="000"
    case "$code" in
      2??) echo "$code"; return 0 ;;
      429|500|502|503|504|000)
        if [ "$attempt" -ge "$HTTP_MAX_RETRIES" ]; then
          echo "$code"; return 1
        fi
        [ "$code" = "429" ] && warn "Rate limited (429). Waiting ${delay}s before retry $attempt/$HTTP_MAX_RETRIES..." \
                            || warn "HTTP $code. Retrying in ${delay}s ($attempt/$HTTP_MAX_RETRIES)..."
        sleep "$delay"; attempt=$((attempt + 1)); delay=$((delay * 2)) ;;
      *) echo "$code"; return 1 ;;
    esac
  done
}

urlencode() { jq -rn --arg s "$1" '$s|@uri'; }
