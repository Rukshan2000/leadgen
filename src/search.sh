#!/usr/bin/env bash
# Business search from legitimate public APIs.
#   - Google Places API (New) Text Search  (needs GOOGLE_PLACES_API_KEY)
#   - OpenStreetMap: Nominatim + Overpass   (free, no key; respects usage policy)
# Every function emits normalized JSON lines (one lead per line).

# Map a free-text category to OpenStreetMap Overpass tag filters (';'-separated).
osm_filters_for_category() {
  local c
  c=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$c" in
    *hotel*|*villa*|*guest*|*hostel*|*resort*|*lodg*)
      echo '["tourism"~"^(hotel|guest_house|hostel|motel|apartment|chalet)$"]' ;;
    *dental*|*dentist*)          echo '["amenity"="dentist"]' ;;
    *clinic*|*doctor*|*medical*|*hospital*)
      echo '["amenity"~"^(clinic|doctors)$"]' ;;
    *construct*|*builder*|*contractor*)
      echo '["craft"~"^(builder|carpenter|electrician|plumber)$"];["office"="construction_company"]' ;;
    *real*estate*|*property*|*estate*)
      echo '["office"="estate_agent"]' ;;
    *rental*|*rent*|*car*hire*|*vehicle*)
      echo '["amenity"~"^(car_rental|motorcycle_rental|bicycle_rental)$"]' ;;
    *wedding*|*event*)
      echo '["amenity"="events_venue"];["shop"="wedding"];["office"="event_management"]' ;;
    *tuition*|*education*|*institute*|*school*|*class*)
      echo '["amenity"~"^(prep_school|language_school|training|college|driving_school)$"]' ;;
    *photo*)                     echo '["craft"="photographer"];["shop"="photo"]' ;;
    *gym*|*fitness*)             echo '["leisure"="fitness_centre"]' ;;
    *salon*|*beauty*|*hair*|*spa*)
      echo '["shop"~"^(hairdresser|beauty|cosmetics)$"]' ;;
    *restaurant*|*cafe*|*food*)  echo '["amenity"~"^(restaurant|cafe|fast_food)$"]' ;;
    *lawyer*|*legal*|*attorney*) echo '["office"="lawyer"]' ;;
    *account*|*tax*|*audit*)     echo '["office"~"^(accountant|tax_advisor)$"]' ;;
    *manufactur*|*factory*|*industr*)
      echo '["industrial"="factory"];["man_made"="works"]' ;;
    *import*|*export*|*wholesale*|*trading*)
      echo '["shop"="wholesale"];["office"~"^(company|logistics)$"]["name"~"(import|export|trading)",i]' ;;
    *)
      # Generic: match the category word against the business name.
      local rx; rx=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9 ]//g')
      echo "[\"name\"~\"${rx}\",i]" ;;
  esac
}

# search_google LOCATION CATEGORY LIMIT
search_google() {
  local location="$1" category="$2" limit="$3"
  if [ -z "${GOOGLE_PLACES_API_KEY:-}" ]; then
    warn "GOOGLE_PLACES_API_KEY is not set in .env - skipping Google Places."
    warn "  Get a key: https://console.cloud.google.com/ (enable 'Places API (New)')."
    return 0
  fi

  local tmp ids; tmp=$(mktemp); ids=$(mktemp)
  local code body mask
  mask='places.id,places.displayName,places.formattedAddress,places.websiteUri,places.nationalPhoneNumber,places.internationalPhoneNumber,places.googleMapsUri,places.rating,places.userRatingCount,places.primaryTypeDisplayName,places.types,places.businessStatus,places.regularOpeningHours.weekdayDescriptions,places.photos.name,places.priceLevel,nextPageToken'
  # Reviews let us spot pain points ("couldn't book", "no one answers") and whether the
  # business is still active. They move the request to a higher Places pricing tier.
  [ "${GOOGLE_FETCH_REVIEWS:-true}" = "true" ] && mask="$mask,places.reviews"

  # Google caps each query at 60 results, so try several phrasings until we have
  # enough unique candidates (2x the requested count, so scoring can pick the best).
  local variants='{c} in {l}|best {c} in {l}|{c} near {l}|local {c} {l}'
  [ -n "${GOOGLE_QUERY_VARIANTS:-}" ] && variants="$GOOGLE_QUERY_VARIANTS"
  local want=$((limit * 2)) v q token pages
  local IFS_OLD="$IFS"; IFS='|'; set -f
  for v in $variants; do
    IFS="$IFS_OLD"
    [ "$(sort -u "$ids" | wc -l | tr -d ' ')" -ge "$want" ] && break
    q=${v//\{c\}/$category}; q=${q//\{l\}/$location}
    log "Google Places: searching \"$q\"..."
    token=""; pages=0
    while [ "$pages" -lt 3 ]; do
      body=$(jq -cn --arg q "$q" --arg t "$token" \
        '{textQuery:$q, pageSize:20} + (if $t=="" then {} else {pageToken:$t} end)')
      if ! code=$(http_request "$tmp" -X POST "https://places.googleapis.com/v1/places:searchText" \
           -H "Content-Type: application/json" \
           -H "X-Goog-Api-Key: $GOOGLE_PLACES_API_KEY" \
           -H "X-Goog-FieldMask: $mask" \
           -d "$body"); then
        err "Google Places request failed (HTTP $code): $(jq -r '.error.message? // empty' "$tmp" 2>/dev/null)"
        [ "$code" = "403" ] && err "  Check the API key and that 'Places API (New)' is enabled with billing."
        IFS='|'; break 2
      fi

      jq -r '.places[]?.id' "$tmp" >> "$ids"
      jq -c --arg cat "$category" '
        .places[]? | select((.businessStatus // "OPERATIONAL") == "OPERATIONAL")
        | (.reviews // []) as $rv
        | ([$rv[] | (.text.text // .originalText.text // "")] | join(" \n ") | ascii_downcase) as $t
        | {
          source: "google_places",
          source_id: .id,
          name: (.displayName.text // ""),
          category: (.primaryTypeDisplayName.text // $cat),
          location: (.formattedAddress // ""),
          website: (.websiteUri // ""),
          phone: (.internationalPhoneNumber // .nationalPhoneNumber // ""),
          email: "",
          profile_url: (.googleMapsUri // ""),
          social_url: "",
          rating: (.rating // null),
          review_count: (.userRatingCount // 0),
          types: (.types // []),
          has_hours: (.regularOpeningHours != null),
          photo_count: ((.photos // []) | length),
          price_level: (.priceLevel // ""),
          reviews_sampled: ($rv | length),
          last_review_date: (([$rv[].publishTime // empty] | max) // "" | .[0:10]),
          low_star_reviews: ([$rv[] | select((.rating // 5) <= 2)] | length),
          review_signals: [
            (if $t | test("website|online|internet|instagram page only|facebook page only") then "mentions website/online" else empty end),
            (if $t | test("book|reserv|appointment|slot") then "mentions booking/appointments" else empty end),
            (if $t | test("(no|never|not|didn.?t|don.?t|couldn.?t|can.?t|won.?t)[^.]{0,30}(answer|respond|reply|pick|call back|reach|contact)|hard to (reach|contact)") then "customers struggle to reach them" else empty end),
            (if $t | test("price list|no price|pricing|menu") then "customers ask about prices/menu" else empty end),
            (if $t | test("hard to find|couldn.?t find|difficult to find|direction") then "hard to find" else empty end),
            (if $t | test("waited|waiting|queue|long wait|delay") then "complaints about waiting/queues" else empty end)
          ]
        }' "$tmp"

      token=$(jq -r '.nextPageToken // empty' "$tmp")
      pages=$((pages + 1))
      [ -z "$token" ] && break
      [ "$(sort -u "$ids" | wc -l | tr -d ' ')" -ge "$want" ] && break
      sleep 2   # next page token needs a moment to become valid
    done
    IFS='|'
  done
  IFS="$IFS_OLD"; set +f
  rm -f "$tmp" "$ids"
}

# search_osm LOCATION CATEGORY LIMIT
search_osm() {
  local location="$1" category="$2" limit="$3"
  local tmp; tmp=$(mktemp)
  local code

  log "OpenStreetMap: locating \"$location\"..."
  if ! code=$(http_request "$tmp" -G "https://nominatim.openstreetmap.org/search" \
        --data-urlencode "q=$location" -d format=json -d limit=1); then
    err "Nominatim lookup failed (HTTP $code)."; rm -f "$tmp"; return 0
  fi
  if [ "$(jq 'length' "$tmp")" -eq 0 ]; then
    warn "Location \"$location\" not found on OpenStreetMap."; rm -f "$tmp"; return 0
  fi

  local osm_type osm_id area_sel
  osm_type=$(jq -r '.[0].osm_type' "$tmp")
  osm_id=$(jq -r '.[0].osm_id' "$tmp")
  if [ "$osm_type" = "relation" ]; then
    area_sel="area(id:$((3600000000 + osm_id)))->.a;"
    local scope="(area.a)"
  else
    # Fall back to bounding box: [south, north, west, east]
    local bbox; bbox=$(jq -r '.[0].boundingbox | "\(.[0]),\(.[2]),\(.[1]),\(.[3])"' "$tmp")
    area_sel=""; local scope="($bbox)"
  fi
  sleep 1  # Nominatim policy: max 1 request/second

  local filters parts="" f
  filters=$(osm_filters_for_category "$category")
  local IFS_OLD="$IFS"; IFS=';'
  for f in $filters; do
    parts="${parts}nwr${f}[\"name\"]${scope};"
  done
  IFS="$IFS_OLD"

  local query="[out:json][timeout:90];${area_sel}(${parts});out center tags $((limit * 3));"
  log "OpenStreetMap: querying Overpass for \"$category\"..."

  local mirrors=(
    "https://overpass-api.de/api/interpreter"
    "https://overpass.kumi.systems/api/interpreter"
    "https://overpass.openstreetmap.ru/api/interpreter"
  )
  local mirror ok=0
  for mirror in "${mirrors[@]}"; do
    if code=$(http_request "$tmp" -X POST "$mirror" --data-urlencode "data=$query"); then
      ok=1; break
    fi
    warn "Overpass mirror $mirror failed (HTTP $code), trying next..."
  done
  if [ "$ok" -ne 1 ]; then
    err "Overpass query failed on all mirrors (last HTTP $code). The public servers may be busy; try again later."
    rm -f "$tmp"; return 0
  fi

  jq -c --arg cat "$category" --arg loc "$location" '.elements[]? | .tags as $t | {
      source: "openstreetmap",
      source_id: "\(.type)/\(.id)",
      name: ($t.name // ""),
      category: ($t.tourism // $t.amenity // $t.shop // $t.office // $t.craft // $t.leisure // $cat),
      location: ([ $t["addr:housenumber"], $t["addr:street"], $t["addr:city"] ] | map(select(. != null)) | join(", ")
                  | if . == "" then $loc else . end),
      website: ($t.website // $t["contact:website"] // $t.url // ""),
      phone: ($t.phone // $t["contact:phone"] // $t["contact:mobile"] // ""),
      email: ($t.email // $t["contact:email"] // ""),
      profile_url: "https://www.openstreetmap.org/\(.type)/\(.id)",
      social_url: ($t["contact:facebook"] // $t.facebook // $t["contact:instagram"] // $t.instagram // ""),
      socials: ([ $t["contact:facebook"], $t.facebook, $t["contact:instagram"], $t.instagram,
                  $t["contact:linkedin"], $t["contact:tiktok"], $t["contact:youtube"] ] | map(select(. != null)) | unique),
      whatsapp: ($t["contact:whatsapp"] // ""),
      rating: null,
      review_count: 0,
      has_hours: ($t.opening_hours != null)
    } | select(.name != "")' "$tmp"
  rm -f "$tmp"
}

# dedupe_leads < jsonl > json-array
# Merges duplicates by normalized name (+ phone digits when present).
dedupe_leads() {
  jq -s '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
    def digits: gsub("[^0-9]"; "") | .[-9:];
    def pick(a; b): if (a // "") != "" then a else b end;
    group_by(.name | norm)
    | map(
        # within same name, split by distinct non-empty phone numbers
        (map(select(.phone != "")) | group_by(.phone | digits)) as $byphone
        | (map(select(.phone == ""))) as $nophone
        | if ($byphone | length) == 0 then [ $nophone ]
          else ($byphone | .[0] += $nophone) end
        | map(reduce .[1:][] as $x (.[0];
            .website     = pick(.website; $x.website)
          | .phone       = pick(.phone; $x.phone)
          | .email       = pick(.email; $x.email)
          | .social_url  = pick(.social_url; $x.social_url)
          | .profile_url = pick(.profile_url; $x.profile_url)
          | .rating      = (.rating // $x.rating)
          | .review_count = ([.review_count, $x.review_count] | max)
          | .has_hours   = ((.has_hours // false) or ($x.has_hours // false))
          | .photo_count = ([.photo_count, $x.photo_count] | max)
          | .last_review_date = ([.last_review_date, $x.last_review_date] | map(select(. != null)) | max // "")
          | .socials     = ((.socials // []) + ($x.socials // []) | unique)
          | .whatsapp    = pick(.whatsapp; $x.whatsapp)
          | .types       = ((.types // []) + ($x.types // []) | unique)
          | .review_signals = ((.review_signals // []) + ($x.review_signals // []) | unique)
          | .reviews_sampled = ([.reviews_sampled, $x.reviews_sampled] | max)
          | .low_star_reviews = ([.low_star_reviews, $x.low_star_reviews] | max)
          | .price_level = pick(.price_level; $x.price_level)
          | .source      = ([.source, $x.source] | unique | join("+"))
          ))
      )
    | flatten
    | map(select(.name != ""))'
}
