#!/usr/bin/env bash
# Add WhatsApp status + wa.me chat links to saved lead results.
# Usage: ./whatsapp_check.sh                 update every saved result in leads/
#        ./whatsapp_check.sh leads/2026-09-13/hotel-galle-sri-lanka_131236.json
# Status is an estimate (see src/whatsapp.sh); WhatsApp itself is never queried.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/src/common.sh"
. "$ROOT/src/output.sh"
. "$ROOT/src/whatsapp.sh"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
command -v jq >/dev/null 2>&1 || { err "'jq' is required."; exit 1; }

if [ $# -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$ROOT/leads" -mindepth 2 -maxdepth 2 -name '*.json' | sort)
fi
[ ${#FILES[@]} -eq 0 ] && { warn "No result files found."; exit 0; }

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { warn "Not found: $f"; continue; }
  whatsapp_enrich "$f" || { warn "Could not update $f"; continue; }
  csv="${f%.json}.csv"
  write_csv "$f" "$csv"
  ok "$(basename "$f"): $(jq -r 'group_by(.wa_status) | map("\(.[0].wa_status) \(length)") | join(", ")' "$f")"
  jq -r '.[] | select(.wa_status == "CONFIRMED" or .wa_status == "LIKELY")
         | "    \(.wa_status | .[0:9] | . + " " * (10 - length))\(.name[0:34] | . + " " * (35 - length))\(.wa_link)"' "$f"
done

build_manifest "$ROOT/leads"
