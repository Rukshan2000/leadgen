#!/usr/bin/env bash
# Lead Finder - find local businesses that likely need a professional website.
# Usage: ./lead_finder.sh            (interactive)
#        ./lead_finder.sh "Colombo, Sri Lanka" "dental clinic" 30

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/src/common.sh"
. "$ROOT/src/search.sh"
. "$ROOT/src/website_check.sh"
. "$ROOT/src/scoring.sh"
. "$ROOT/src/output.sh"

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || { err "'$dep' is required. Install it (e.g. brew install $dep)."; exit 1; }
done

if [ -f "$ROOT/.env" ]; then
  set -a; . "$ROOT/.env"; set +a
else
  warn "No .env file found. Copy config.example.env to .env to add API keys."
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "${C_GRN}=== Lead Finder ===${C_RST}"
LOCATION="${1:-}"; CATEGORY="${2:-}"; LIMIT="${3:-}"
[ -z "$LOCATION" ] && read -r -p "Location / city / country (e.g. Kandy, Sri Lanka): " LOCATION
[ -z "$CATEGORY" ] && read -r -p "Business category (e.g. hotel, dental clinic, gym): " CATEGORY
[ -z "$LIMIT" ]    && read -r -p "Number of leads wanted [20]: " LIMIT
LIMIT="${LIMIT:-20}"

if [ -z "$LOCATION" ] || [ -z "$CATEGORY" ]; then err "Location and category are required."; exit 1; fi
case "$LIMIT" in ''|*[!0-9]*) err "Number of leads must be a positive integer."; exit 1 ;; esac
[ "$LIMIT" -lt 1 ] && { err "Number of leads must be at least 1."; exit 1; }

SOURCES="${LEAD_SOURCES:-google,osm}"
RAW="$WORK/raw.jsonl"; : > "$RAW"
case ",$SOURCES," in *,google,*) search_google "$LOCATION" "$CATEGORY" "$LIMIT" >> "$RAW" ;; esac
case ",$SOURCES," in *,osm,*)    search_osm    "$LOCATION" "$CATEGORY" "$LIMIT" >> "$RAW" ;; esac

if [ ! -s "$RAW" ]; then
  err "No businesses found. Try a broader location or a different category wording."
  exit 1
fi

dedupe_leads < "$RAW" > "$WORK/unique.json"
TOTAL=$(jq length "$WORK/unique.json")
ok "Found $(wc -l < "$RAW" | tr -d ' ') raw results, $TOTAL unique businesses."

# Check websites and score every unique lead in parallel, then keep the best LIMIT.
mkdir -p "$WORK/leads"
jq -c '.[]' "$WORK/unique.json" | split -l 1 -a 4 - "$WORK/leads/lead_"
JOBS="${CHECK_CONCURRENCY:-8}"
log "Checking websites and scoring $TOTAL businesses ($JOBS in parallel)..."
find "$WORK/leads" -name 'lead_*' ! -name '*.out' -print0 \
  | xargs -0 -P "$JOBS" -I{} bash "$ROOT/src/process_lead.sh" {} "$CATEGORY" &
XPID=$!
while kill -0 "$XPID" 2>/dev/null; do
  done_n=$(find "$WORK/leads" -name '*.out' | wc -l | tr -d ' ')
  printf '\r%s[....]%s Checked %d/%d' "$C_BLU" "$C_RST" "$done_n" "$TOTAL" >&2
  sleep 1
done
wait "$XPID"
printf '\r%s[ ok ]%s Checked %d/%d\n' "$C_GRN" "$C_RST" "$(find "$WORK/leads" -name '*.out' | wc -l | tr -d ' ')" "$TOTAL" >&2
cat "$WORK"/leads/*.out > "$WORK/scored.jsonl" 2>/dev/null

MIN_SCORE="${MIN_SCORE:-0}"
jq -s --argjson n "$LIMIT" --argjson min "$MIN_SCORE" --arg loc "$LOCATION" --arg cat "$CATEGORY" \
  'map(select(.lead_score >= $min))
   | sort_by(-.lead_score, -(.review_count // 0)) | .[:$n]
   | map({name, category, location, priority, lead_score, website_status, pitch, opportunities,
          phone, email, whatsapp:(.whatsapp // ""), website, social_url, socials:(.socials // []),
          profile_url, rating, review_count, last_review_date:(.last_review_date // ""),
          review_signals:(.review_signals // []), photo_count:(.photo_count // null),
          has_hours:(.has_hours // null), emails_found:(.emails_found // []),
          website_check, score_reasons, source,
          search_location:$loc, search_category:$cat})' \
  "$WORK/scored.jsonl" > "$WORK/final.json"

COUNT=$(jq length "$WORK/final.json")
[ "$COUNT" -lt "$LIMIT" ] && warn "Only $COUNT leads available (requested $LIMIT)."

SLUG=$(printf '%s_%s' "$CATEGORY" "$LOCATION" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
OUT_DIR="$ROOT/leads/$(date +%Y-%m-%d)"
write_outputs "$WORK/final.json" "$OUT_DIR" "${SLUG}_$(date +%H%M%S)"

# Auto-cleanup of old results (LEADS_RETENTION_DAYS, 0 = keep forever).
"$ROOT/clean_leads.sh" "${LEADS_RETENTION_DAYS:-30}"
