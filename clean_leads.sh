#!/usr/bin/env bash
# Delete old lead results to save storage.
# Usage: ./clean_leads.sh [DAYS]        remove leads/YYYY-MM-DD folders older than DAYS
#        ./clean_leads.sh --dry-run 7   show what would be removed
# DAYS defaults to LEADS_RETENTION_DAYS (.env) or 30. 0 disables cleanup.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/src/common.sh"
. "$ROOT/src/output.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

DRY=false
[ "${1:-}" = "--dry-run" ] && { DRY=true; shift; }
DAYS="${1:-${LEADS_RETENTION_DAYS:-30}}"
case "$DAYS" in ''|*[!0-9]*) err "DAYS must be a whole number."; exit 1 ;; esac
[ "$DAYS" -eq 0 ] && { log "Cleanup disabled (retention 0 days)."; exit 0; }

# Cutoff date on both macOS (BSD date) and Linux (GNU date).
CUTOFF=$(date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d)
LEADS="$ROOT/leads"

removed=0; freed=0
for dir in "$LEADS"/????-??-??; do
  [ -d "$dir" ] || continue
  day=$(basename "$dir")
  # Folder names are ISO dates, so string comparison orders them correctly.
  if [[ "$day" < "$CUTOFF" ]]; then
    kb=$(du -sk "$dir" | cut -f1)
    if $DRY; then
      log "Would remove $day (${kb} KB)"
    else
      rm -rf "$dir" && log "Removed $day (${kb} KB)"
    fi
    removed=$((removed + 1)); freed=$((freed + kb))
  fi
done

if [ "$removed" -eq 0 ]; then
  ok "Nothing older than $DAYS days (before $CUTOFF)."
elif $DRY; then
  ok "Dry run: $removed folder(s), ${freed} KB would be freed."
else
  ok "Removed $removed folder(s), freed ${freed} KB."
  build_manifest "$LEADS"
fi
