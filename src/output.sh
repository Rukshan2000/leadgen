#!/usr/bin/env bash
# Output: terminal table, CSV, JSON.

# write_outputs LEADS_JSON_FILE OUT_DIR BASENAME
write_outputs() {
  local in="$1" dir="$2" base="$3"
  mkdir -p "$dir"
  local json="$dir/$base.json" csv="$dir/$base.csv"

  jq '.' "$in" > "$json"

  jq -r '
    ["priority","lead_score","name","category","location","website_status","pitch","opportunities",
     "phone","email","whatsapp","website","social_url","other_socials","profile_url","rating","review_count",
     "last_review_date","review_signals","photo_count","http_status","https","load_seconds","tech",
     "page_title","website_issues","missing_features","score_reasons","source"],
    (.[] | (.website_check // {}) as $wc | [
      .priority, .lead_score, .name, .category, .location, .website_status, .pitch,
      ((.opportunities // []) | join("; ")),
      .phone, .email, .whatsapp, .website, .social_url, ((.socials // []) | join(" ")), .profile_url,
      (.rating // ""), .review_count, .last_review_date, ((.review_signals // []) | join("; ")),
      (.photo_count // ""), ($wc.http_status // ""), ($wc.https // ""), ($wc.load_seconds // ""),
      ($wc.tech // ""), ($wc.title // ""), (($wc.issues // []) | join("; ")),
      (($wc.features // {}) | to_entries | map(select(.value == false) | .key) | join("; ")),
      ((.score_reasons // []) | join("; ")), .source ])
    | @csv' "$in" > "$csv"

  print_table "$in"
  ok "JSON saved: $json"
  ok "CSV  saved: $csv"
  build_manifest "$(dirname "$dir")"
}

# build_manifest LEADS_ROOT
# Writes leads/manifest.js listing every results file (with its data), so
# index.html can preview them directly from disk (file:// can't fetch JSON).
build_manifest() {
  local root="$1" tmp f
  tmp=$(mktemp)
  : > "$tmp"
  find "$root" -mindepth 2 -maxdepth 2 -name '*.json' | sort -r | while IFS= read -r f; do
    jq -c --arg path "${f#"$root"/}" '{
        path: $path,
        date: ($path | split("/")[0]),
        location: (.[0].search_location // ""),
        category: (.[0].search_category // ""),
        count: length,
        leads: .
      }' "$f" >> "$tmp" 2>/dev/null || warn "Skipping unreadable file: $f"
  done
  { printf 'window.LEAD_FILES = '; jq -s '.' "$tmp"; printf ';\n'; } > "$root/manifest.js"
  rm -f "$tmp"
  ok "Preview index updated: $root/manifest.js (open index.html)"
}

print_table() {
  local in="$1"
  echo
  jq -r '
    def cut(n): tostring | if length > n then .[0:n-1] + "…" else . end;
    def pad(n): cut(n) | . + (" " * (n - length));
    (["#","SCORE","PRIO","STATUS","NAME","PHONE","TOP OPPORTUNITY"] as $h
      | "\($h[0]|pad(3)) \($h[1]|pad(5)) \($h[2]|pad(5)) \($h[3]|pad(12)) \($h[4]|pad(30)) \($h[5]|pad(18)) \($h[6])"),
    ("-" * 120),
    (to_entries[] | .key as $i | .value |
      "\(($i+1)|pad(3)) \(.lead_score|pad(5)) \(.priority|pad(5)) \(.website_status|pad(12)) \(.name|pad(30)) \(.phone|pad(18)) \((.opportunities[0] // "")|cut(44))")
  ' "$in"
  echo
}
