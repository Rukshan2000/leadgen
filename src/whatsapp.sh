#!/usr/bin/env bash
# WhatsApp enrichment: normalise phone numbers and build wa.me chat links.
#
# There is no official, allowed way to ask WhatsApp whether any number has an account,
# so this does not query WhatsApp. It estimates instead:
#   CONFIRMED  business publishes a WhatsApp number (OpenStreetMap tag or wa.me link on its site)
#   LIKELY     a mobile number (in countries where mobile ranges are known)
#   UNKNOWN    valid number, but mobile/landline can't be told apart (e.g. US/Canada)
#   UNLIKELY   a landline number
#   NO_NUMBER  no usable phone number
# Opening the wa.me link shows for certain: WhatsApp says if the number isn't on WhatsApp.

# whatsapp_enrich JSON_ARRAY_FILE [LOCATION]   (edits the file in place)
whatsapp_enrich() {
  local file="$1" tmp
  tmp=$(mktemp)
  jq --arg loc "${2:-}" --arg dcc "${DEFAULT_COUNTRY_CODE:-}" '
    def cc_for_location:
      ascii_downcase
      | if   test("sri lanka|colombo|kandy|galle|jaffna|negombo|matara|kurunegala") then "94"
        elif test("singapore") then "65"
        elif test("india|mumbai|delhi|bangalore|bengaluru|chennai|hyderabad|kolkata") then "91"
        elif test("malaysia|kuala lumpur|penang|johor") then "60"
        elif test("uae|united arab emirates|dubai|abu dhabi|sharjah") then "971"
        elif test("australia|sydney|melbourne|brisbane|perth") then "61"
        elif test("united kingdom|england|london|manchester|scotland") then "44"
        elif test("thailand|bangkok|phuket") then "66"
        elif test("indonesia|jakarta|bali") then "62"
        elif test("maldives") then "960"
        elif test("united states|usa|canada|new york|toronto") then "1"
        else $dcc end;
    # Country codes we know mobile ranges for (longest first so 971 beats 9x).
    def known_ccs: ["971","960","94","91","65","66","62","61","60","44","1"];
    def is_mobile($cc; $n):
      if   $cc == "94"  then ($n | test("^7[0-8][0-9]{7}$"))
      elif $cc == "65"  then ($n | test("^[89][0-9]{7}$"))
      elif $cc == "91"  then ($n | test("^[6-9][0-9]{9}$"))
      elif $cc == "60"  then ($n | test("^1[0-9]{8,9}$"))
      elif $cc == "971" then ($n | test("^5[0-9]{8}$"))
      elif $cc == "61"  then ($n | test("^4[0-9]{8}$"))
      elif $cc == "44"  then ($n | test("^7[0-9]{9}$"))
      elif $cc == "66"  then ($n | test("^[689][0-9]{8}$"))
      elif $cc == "62"  then ($n | test("^8[0-9]{8,11}$"))
      elif $cc == "960" then ($n | test("^[79][0-9]{6}$"))
      else null end;
    # Raw phone text -> international digits (no +), or "" if unusable.
    def to_intl($cc):
      gsub("[^0-9+]"; "")
      | if   startswith("+")  then .[1:]
        elif startswith("00") then .[2:]
        elif startswith("0") and $cc != "" then $cc + .[1:]
        elif $cc != "" and length <= 10 then $cc + .
        else . end
      | gsub("[^0-9]"; "")
      | if length >= 8 and length <= 15 then . else "" end;
    def analyse($raw; $listed; $cc0):
      ($raw | to_intl($cc0)) as $d
      | select($d != "")
      | (first(known_ccs[] as $c | select($d | startswith($c)) | $c) // "") as $cc
      | {number: $d, listed: $listed,
         mobile: (if $cc == "" then null else is_mobile($cc; $d[($cc | length):]) end)};

    map(
      ((.search_location // $loc) | cc_for_location) as $cc0
      | ([ ((.whatsapp // "") | split("[;,/]"; null)[] | analyse(.; true; $cc0)),
           ((.phone // "")    | split("[;,/]"; null)[] | analyse(.; false; $cc0)) ]) as $cands
      | (first($cands[] | select(.listed)) // first($cands[] | select(.mobile == true))
         // first($cands[] | select(.mobile == null)) // first($cands[]) // null) as $best
      | .wa_number = ($best.number // "")
      | .wa_status = (if $best == null then "NO_NUMBER"
                      elif $best.listed then "CONFIRMED"
                      elif $best.mobile == true then "LIKELY"
                      elif $best.mobile == null then "UNKNOWN"
                      else "UNLIKELY" end)
      | .wa_link = (if $best == null then "" else "https://wa.me/" + $best.number end)
    )' "$file" > "$tmp" && mv "$tmp" "$file"
}
