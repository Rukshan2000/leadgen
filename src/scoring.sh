#!/usr/bin/env bash
# Lead scoring (0-100) + sales opportunities for a web/system developer.
# Higher score = more likely to need (and pay for) a website or custom system.

HIGH_VALUE_CATEGORY_RX='hotel|villa|guest|resort|lodg|hostel|clinic|dent|doctor|medical|construct|builder|real|estate|rental|rent|wedding|event|tuition|education|school|institute|photo|gym|fitness|salon|beauty|hair|spa|restaurant|cafe|lawyer|legal|account|tax|manufactur|factory|import|export|wholesale'
BOOKING_CATEGORY_RX='hotel|villa|guest|resort|lodg|hostel|clinic|dent|doctor|medical|physio|salon|beauty|hair|spa|barber|nail|gym|fitness|yoga|restaurant|cafe|rental|rent|hire|tuition|class|photo|wedding|event|tour'
SHOP_CATEGORY_RX='shop|store|boutique|bakery|florist|pharmac|furniture|cloth|fashion|jewel|electronic|hardware|manufactur|factory|wholesale|import|export|trading|supplier'

# score_lead LEAD_JSON SEARCH_CATEGORY
#   -> LEAD_JSON with lead_score, priority, score_reasons, opportunities, pitch
score_lead() {
  printf '%s' "$1" | jq -c --arg rx "$HIGH_VALUE_CATEGORY_RX" --arg brx "$BOOKING_CATEGORY_RX" \
      --arg srx "$SHOP_CATEGORY_RX" --arg cat "$2" --arg today "$(date +%Y-%m-%d)" '
    def days_since($d): if ($d // "") == "" then null
      else (($today + "T00:00:00Z" | fromdateiso8601) - ($d[0:10] + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor end;
    def system_for:
      if   test("hotel|villa|guest|resort|lodg|hostel|homestay") then "Direct booking engine (save OTA commission)"
      elif test("dent|clinic|doctor|medical|hospital|physio|pharm") then "Patient appointment & records system"
      elif test("tuition|school|institute|education|class|academy|college|training") then "Student management / online class portal"
      elif test("gym|fitness|yoga") then "Membership, attendance & billing system"
      elif test("salon|beauty|hair|spa|barber|nail") then "Appointment booking + client reminders"
      elif test("restaurant|cafe|food|bakery|bar") then "Online ordering / QR menu system"
      elif test("construct|builder|contractor|carpenter|electric|plumb|architect") then "Project portfolio + quote request system"
      elif test("real|estate|property") then "Property listing portal with inquiry CRM"
      elif test("rental|rent|hire") then "Fleet availability & booking system"
      elif test("wedding|event|photo") then "Portfolio + inquiry & booking calendar"
      elif test("lawyer|legal|attorney|account|tax|audit") then "Client portal & secure document upload"
      elif test("manufactur|factory|import|export|wholesale|trading|industr") then "B2B product catalogue + inquiry/inventory system"
      else empty end;

    ((.category // "") + " " + $cat + " " + ((.types // []) | join(" ")) | ascii_downcase) as $c
    | (.website_check // {}) as $wc
    | ($wc.features // {}) as $f
    | (.review_count // 0) as $rc
    | days_since(.last_review_date) as $age
    | (.website_status == "NO_WEBSITE") as $nows
    | (.website_status == "WEAK_WEBSITE") as $weak
    | (.website_status == "HAS_WEBSITE") as $hasws
    | (((.socials // []) | length > 0) or (.social_url // "") != "") as $social
    | [
        (if $nows then ["No website", 35] else empty end),
        (if $weak then ["Weak/outdated website", 20] else empty end),
        (if $nows and $social then ["Active on social media but no website", 10] else empty end),
        (if $rc >= 50 then ["Busy business (\($rc) reviews)", 15]
         elif $rc >= 20 then ["Strong public presence (\($rc) reviews)", 10]
         elif $rc >= 5 then ["Some public presence (\($rc) reviews)", 5] else empty end),
        (if (.rating // 0) >= 4.3 and $rc >= 10 then ["Well rated (\(.rating)★) - values its reputation", 5] else empty end),
        (if $age != null and $age <= 180 then ["Recently active (review \($age) days ago)", 5]
         elif $age != null and $age > 730 then ["No reviews in 2+ years - may be inactive", -15] else empty end),
        (if ($c | test($rx)) then ["Category benefits strongly from a website", 10] else empty end),
        (if (.phone // "") != "" or (.email // "") != "" then ["Public contact info available", 5]
         else ["No phone or email - hard to contact", -10] end),
        (if ((.review_signals // []) | length) > 0 then ["Reviews show pain points: \(.review_signals | join(", "))", 8] else empty end),
        (if $hasws and ($c | test($brx)) and ($f.online_booking == false) then ["Website has no online booking", 8] else empty end),
        (if $hasws and ($f.analytics == false or $f.meta_description == false) then ["Website lacks SEO/analytics basics", 4] else empty end)
      ] as $r
    | [
        (if $nows then "New professional website" else empty end),
        (if $nows and $social then "Website to turn social followers into direct inquiries" else empty end),
        (if $weak then "Website redesign (\(($wc.issues // []) | .[0:3] | join(", ")))" else empty end),
        (if ($wc.reachable == true) and ($wc.https == false) then "SSL/HTTPS setup" else empty end),
        (if (($wc.issues // []) | map(test("mobile")) | any) then "Mobile-responsive rebuild" else empty end),
        (if (($wc.issues // []) | map(test("slow")) | any) then "Speed optimisation / hosting upgrade" else empty end),
        (if (($wc.tech // "") | test("Wix|Weebly|GoDaddy")) or (($wc.issues // []) | map(test("free subdomain")) | any)
         then "Migrate from site builder to own domain/custom site" else empty end),
        (if ($c | test($brx)) and ($nows or $f.online_booking == false) then "Online booking / reservation system" else empty end),
        (if ($c | test($srx)) and ($nows or $f.ecommerce == false) then "E-commerce / online catalogue" else empty end),
        ($c | system_for),
        (if $hasws and ($f.meta_description == false or $f.structured_data == false) then "SEO & Google visibility" else empty end),
        (if $hasws and $f.analytics == false then "Analytics & conversion tracking" else empty end),
        (if (.phone // "") != "" and ($f.whatsapp_button != true) and (.whatsapp // "") == "" then "WhatsApp click-to-chat integration" else empty end),
        (if (.review_signals // []) | index("customers struggle to reach them") then "Inquiry form / chatbot / auto-reply (customers cannot reach them)" else empty end),
        (if (.rating // 5) < 3.8 and $rc >= 10 then "Customer feedback & review management system" else empty end),
        (if .source != null and (.source | test("google")) and ((.has_hours // true) == false or (.photo_count // 10) < 5)
         then "Google Business Profile optimisation" else empty end)
      ] as $opps
    | .lead_score = ([$r[][1]] | add // 0 | if . > 100 then 100 elif . < 0 then 0 else . end)
    | .priority = (if .lead_score >= 70 then "HOT" elif .lead_score >= 45 then "WARM" else "COLD" end)
    | .score_reasons = [$r[] | "\(.[0]) (\(if .[1] >= 0 then "+" else "" end)\(.[1]))"]
    | .opportunities = (reduce $opps[] as $o ([]; if index([$o]) then . else . + [$o] end))
    | .pitch = (if (.opportunities | length) == 0 then ""
                else "Offer: " + (.opportunities[0:2] | join(" + ")) end)'
}
