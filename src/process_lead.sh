#!/usr/bin/env bash
# Worker: check website + score one lead. Run in parallel by lead_finder.sh.
# Usage: process_lead.sh LEAD_FILE SEARCH_CATEGORY   (writes LEAD_FILE.out)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/src/common.sh"
. "$ROOT/src/website_check.sh"
. "$ROOT/src/scoring.sh"

lead=$(check_website "$(cat "$1")")
score_lead "$lead" "$2" > "$1.out"
