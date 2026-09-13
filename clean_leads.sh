#!/usr/bin/env bash
# Delete old lead results to save storage.
# Usage: ./clean_leads.sh [DAYS]        remove leads/YYYY-MM-DD folders older than DAYS
#        ./clean_leads.sh --dry-run 7   show what would be removed
# DAYS defaults to LEADS_RETENTION_DAYS (.env) or 30. 0 removes everything, including today.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/src/common.sh"
. "$ROOT/src/output.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

DRY=false
[ "${1:-}" = "--dry-run" ] && { DRY=true; shift; }
DAYS="${1:-${LEADS_RETENTION_DAYS:-30}}"
case "$DAYS" in ''|*[!0-9]*) err "DAYS must be a whole number."; exit 1 ;; esac

# Cutoff date on both macOS (BSD date) and Linux (GNU date).
# DAYS=0 uses tomorrow as the cutoff, so today's folder is included.
if [ "$DAYS" -eq 0 ]; then
  CUTOFF=$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d "+1 day" +%Y-%m-%d)
else
  CUTOFF=$(date -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "-${DAYS} days" +%Y-%m-%d)
fi
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
  ok "Nothing to remove (no results before $CUTOFF)."
elif $DRY; then
  ok "Dry run: $removed folder(s), ${freed} KB would be freed."
else
  ok "Removed $removed folder(s), freed ${freed} KB."
  build_manifest "$LEADS"
fi
