#!/usr/bin/env bash
# Lightweight, non-intrusive website check: one GET of the homepage (+ one HTTPS probe).
# Besides quality issues it records what the site is missing (booking, SEO, analytics...)
# and collects public emails / social links shown on the homepage.

SOCIAL_HOST_RX='(facebook\.com|fb\.com|instagram\.com|linkedin\.com|twitter\.com|x\.com|tiktok\.com|wa\.me|whatsapp\.com|youtube\.com)'
FREE_HOST_RX='(\.wixsite\.com|\.blogspot\.|\.wordpress\.com|sites\.google\.com|\.weebly\.com|\.business\.site|\.godaddysites\.com|linktr\.ee|\.jimdosite\.com|\.webnode\.)'

# check_website LEAD_JSON -> LEAD_JSON with website_status + website_check fields
check_website() {
  local lead="$1" url
  url=$(printf '%s' "$lead" | jq -r '.website')

  if [ -z "$url" ]; then
    printf '%s' "$lead" | jq -c '.website_status="NO_WEBSITE" | .website_check={}'
    return
  fi

  # A social-media page listed as "website" is not a real website.
  if printf '%s' "$url" | grep -Eiq "$SOCIAL_HOST_RX"; then
    printf '%s' "$lead" | jq -c --arg u "$url" '
      .social_url = (if .social_url=="" then $u else .social_url end)
      | .socials = ((.socials // []) + [$u] | unique)
      | .website = "" | .website_status="NO_WEBSITE"
      | .website_check={note:"listed website is a social media page"}'
    return
  fi

  case "$url" in http://*|https://*) ;; *) url="http://$url" ;; esac

  local body flat meta code rest secs final https_ok="false" title issues=""
  body=$(mktemp); flat=$(mktemp)
  meta=$(curl -sL -A "$USER_AGENT" --connect-timeout 8 --max-time 20 --max-filesize 3000000 \
              -o "$body" -w '%{http_code} %{time_total} %{url_effective}' "$url" 2>/dev/null) || meta="000 0 $url"
  code=${meta%% *}; rest=${meta#* }; secs=${rest%% *}; final=${rest#* }

  case "$final" in https://*) https_ok="true" ;; esac
  if [ "$https_ok" = "false" ] && [ "$code" != "000" ]; then
    local https_url="https://${url#*://}"
    curl -sI -A "$USER_AGENT" --connect-timeout 5 --max-time 8 "$https_url" >/dev/null 2>&1 && https_ok="true"
  fi

  if [ "$code" = "000" ] || [ "$code" -ge 400 ] 2>/dev/null; then
    rm -f "$body" "$flat"
    printf '%s' "$lead" | jq -c --arg code "$code" --arg final "$final" '
      .website_status="WEAK_WEBSITE"
      | .website_check={reachable:false, http_status:$code, https:false, title:"", final_url:$final,
                        issues:["site unreachable or returns error"]}'
    return
  fi

  tr '\n\r\t' '   ' < "$body" > "$flat"
  has() { grep -Eiq "$1" "$flat"; }
  title=$(grep -Eio '<title[^>]*>[^<]*</title>' "$flat" | head -1 \
          | sed -E 's/<[^>]+>//g; s/^[[:space:]]+|[[:space:]]+$//g' | cut -c1-120)

  # --- Signs of an outdated / poor site (these decide WEAK_WEBSITE) ---
  add() { issues="${issues}${issues:+|}$1"; }
  [ "$https_ok" = "false" ] && add "no HTTPS"
  has '<meta[^>]+name=["'"'"']?viewport' || add "not mobile-friendly (no viewport meta)"
  [ -z "$title" ] && add "missing page title"
  has 'under construction|coming soon|domain (is )?for sale|parked|default web page|it works!' \
    && add "placeholder/parked page"
  has '\.swf|<frameset|<marquee|<font ' && add "legacy HTML (flash/frames/font tags)"
  has 'jquery[-.]1\.[0-9]' && add "very old jQuery"
  printf '%s' "$final" | grep -Eiq "$FREE_HOST_RX" && add "free subdomain / site builder"
  local size; size=$(wc -c < "$body" | tr -d ' ')
  [ "$size" -lt 1500 ] && add "very little content"
  local yr now; now=$(date +%Y)
  yr=$(grep -Eio '(©|&copy;|copyright)[^0-9]{0,20}(19|20)[0-9]{2}([^0-9]{1,3}(19|20)[0-9]{2})?' "$flat" \
        | grep -Eo '(19|20)[0-9]{2}' | sort -n | tail -1)
  [ -n "$yr" ] && [ "$yr" -le $((now - 3)) ] && add "copyright year $yr looks stale"
  awk -v s="$secs" 'BEGIN{exit !(s > 5)}' && add "slow homepage (${secs%.*}s+)"

  # --- What the site offers (used to find upsell opportunities) ---
  local f_booking=false f_shop=false f_form=false f_wa=false f_analytics=false f_meta=false f_schema=false f_og=false
  has 'book (now|online|a table|an appointment)|booking|reserv|appointment|calendly|fresha|simplybook|setmore|opentable|cloudbeds|beds24|checkfront' && f_booking=true
  has 'add[ -]to[ -]cart|woocommerce|shopify|checkout|/cart|shopping[ -]bag' && f_shop=true
  has '<form' && f_form=true
  has 'wa\.me/|api\.whatsapp\.com|whatsapp://' && f_wa=true
  has 'googletagmanager|google-analytics|gtag\(|fbq\(|clarity\.ms|hotjar' && f_analytics=true
  has '<meta[^>]+name=["'"'"']?description' && f_meta=true
  has 'application/ld\+json|itemtype=["'"'"']?https?://schema\.org' && f_schema=true
  has 'property=["'"'"']?og:' && f_og=true

  local tech=""
  has 'wp-content|wp-includes' && tech="WordPress"
  has 'wixstatic\.com|wix\.com' && tech="Wix"
  has 'squarespace' && tech="Squarespace"
  has 'cdn\.shopify\.com' && tech="Shopify"
  has 'joomla' && tech="Joomla"
  has 'drupal' && tech="Drupal"
  has 'weebly' && tech="Weebly"
  has 'godaddy|img1\.wsimg\.com' && [ -z "$tech" ] && tech="GoDaddy Builder"
  has '__next|_next/static' && tech="Next.js"

  local emails socials
  emails=$(grep -Eio '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$flat" \
           | grep -Eiv '\.(png|jpe?g|gif|svg|webp)$|example\.|sentry|wixpress|domain\.com|email\.com|yourmail' \
           | tr '[:upper:]' '[:lower:]' | sort -u | head -3 | paste -sd'|' -)
  socials=$(grep -Eio 'https?://(www\.)?(facebook|instagram|linkedin|tiktok|youtube)\.com/[^"'"'"' <>?#]+' "$flat" \
            | grep -Eiv '/sharer|/share|/plugins|/tr$|/dialog' | sort -u | head -5 | paste -sd'|' -)
  rm -f "$body" "$flat"

  printf '%s' "$lead" | jq -c --arg code "$code" --arg https "$https_ok" --arg title "$title" \
      --arg final "$final" --arg issues "$issues" --arg secs "$secs" --arg tech "$tech" \
      --arg emails "$emails" --arg socials "$socials" \
      --argjson booking "$f_booking" --argjson shop "$f_shop" --argjson form "$f_form" \
      --argjson wa "$f_wa" --argjson analytics "$f_analytics" --argjson meta "$f_meta" \
      --argjson schema "$f_schema" --argjson og "$f_og" '
    def list: if . == "" then [] else split("|") end;
    ($issues | list) as $iss
    | ($emails | list) as $em
    | ($socials | list) as $so
    | .website_status = (if ($iss|length) >= 2 then "WEAK_WEBSITE" else "HAS_WEBSITE" end)
    | .email = (if .email == "" and ($em|length) > 0 then $em[0] else .email end)
    | .emails_found = $em
    | .socials = ((.socials // []) + $so | unique)
    | .social_url = (if .social_url == "" and ($so|length) > 0 then $so[0] else .social_url end)
    | .website_check = {reachable:true, http_status:$code, https:($https=="true"),
                        title:$title, final_url:$final, load_seconds:($secs|tonumber? // null),
                        tech:$tech, issues:$iss,
                        features:{online_booking:$booking, ecommerce:$shop, contact_form:$form,
                                  whatsapp_button:$wa, analytics:$analytics, meta_description:$meta,
                                  structured_data:$schema, social_preview:$og}}'
}
