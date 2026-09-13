# Lead Finder

Finds local businesses that likely need a professional website (no website, or a weak/outdated one), scores them 0–100, and saves the results as CSV + JSON.

## Setup

```bash
brew install jq          # curl ships with macOS
cp config.example.env .env
# optional: add GOOGLE_PLACES_API_KEY to .env
chmod +x lead_finder.sh
```

## Run

```bash
./lead_finder.sh                                   # interactive
./lead_finder.sh "Galle, Sri Lanka" "hotel" 30     # non-interactive
```

Results: `leads/YYYY-MM-DD/<category>_<location>_<time>.csv|json`

## Sources (legitimate public APIs only)

| Source | Key | Gives |
|---|---|---|
| Google Places API (New) | `GOOGLE_PLACES_API_KEY` | name, address, website, phone, Maps URL, rating, reviews |
| OpenStreetMap (Nominatim + Overpass) | none | name, address, website, phone, email, social links |

No scraping of websites that forbid it and no anti-bot bypassing. Missing fields stay empty — nothing is invented.

## Website status

- `NO_WEBSITE` – no website listed (or only a Facebook/Instagram page)
- `WEAK_WEBSITE` – unreachable, or 2+ issues: no HTTPS, no mobile viewport, missing title, parked page, legacy HTML, old jQuery, free subdomain, stale copyright year, very little content
- `HAS_WEBSITE` – reachable, looks fine
- `UNKNOWN` – reserved for when a check can't be made

The website check is a single homepage GET — no scanning.

## What each lead includes

- **Priority** `HOT` (70+), `WARM` (45–69), `COLD`
- **Opportunities**: what you can sell. Examples: new website, redesign, HTTPS, mobile rebuild, speed fix, moving off Wix/free builders, online booking, e-commerce, SEO, analytics, WhatsApp chat, Google Business Profile tuning, and a custom system for the category (clinic appointments, student portal, gym memberships, hotel booking engine, QR menu, property portal, B2B catalogue...)
- **Pitch**: the top two opportunities as one line
- **Google data**: rating, number of reviews, date of the latest review, photo count, whether opening hours are listed
- **Review insights** (`GOOGLE_FETCH_REVIEWS=true`): flags reviews that mention booking, the website, people not being able to reach the business, prices or menus, being hard to find, or waiting
- **Website check**: speed, CMS/builder, issues, missing features (booking, shop, contact form, WhatsApp, analytics, meta description, structured data, social preview), plus emails and social links found on the homepage

## Scoring

| Signal | Points |
|---|---|
| No website | +35 |
| Weak/outdated website | +20 |
| Social media but no website | +10 |
| 50+ reviews / 20+ / 5+ | +15 / +10 / +5 |
| Rating 4.3+ with 10+ reviews | +5 |
| Latest review within 6 months | +5 |
| No reviews in over 2 years | −15 |
| Category benefits strongly from a website | +10 |
| Public phone/email / none at all | +5 / −10 |
| Reviews show pain points | +8 |
| Booking-type business whose site has no booking | +8 |
| Site missing SEO/analytics basics | +4 |

Google returns at most 60 results per query, so several phrasings are tried (`GOOGLE_QUERY_VARIANTS`) until there are twice as many candidates as you asked for. The top-scoring ones are kept.

## WhatsApp outreach

Every lead gets `wa_status`, `wa_number` and a `wa_link` (`https://wa.me/<number>`). WhatsApp offers no allowed way to check whether a number has an account, so the status is an estimate:

- `CONFIRMED`: the business publishes this WhatsApp number (OpenStreetMap tag or a wa.me link on its website)
- `LIKELY`: mobile number (known ranges for LK, SG, IN, MY, AE, AU, UK, TH, ID, MV)
- `UNKNOWN`: can't tell mobile from landline (e.g. US/Canada)
- `UNLIKELY`: landline
- `NO_NUMBER`

Numbers without a country code use the search location, or `DEFAULT_COUNTRY_CODE` in `.env`.

In the web app, **💬 WhatsApp** lists the numbers for the open search. **Open chat** opens WhatsApp with your message template filled in, and WhatsApp itself tells you if the number isn't registered. Mark each one as *On WA*, *Not on WA* or *Contacted*. Marks are saved to `leads/whatsapp_marks.json` and are kept when old results are cleaned up.

Add WhatsApp data to results saved before this feature:

```bash
./whatsapp_check.sh                                   # all saved results
./whatsapp_check.sh leads/2026-09-13/some-file.json   # one file
```

## Cleaning old results

After each search, result folders older than `LEADS_RETENTION_DAYS` (default 30, `0` = keep forever) are deleted. Run it manually any time:

```bash
./clean_leads.sh --dry-run 7   # show what would be deleted
./clean_leads.sh 7             # delete folders older than 7 days
docker compose exec leadfinder ./clean_leads.sh 7   # inside Docker
```

## Structure

```
lead_finder.sh        main launcher
src/common.sh         logging, HTTP retries / rate-limit backoff
src/search.sh         Google Places + OpenStreetMap search, dedupe
src/website_check.sh  lightweight homepage check
src/scoring.sh        lead score, priority, opportunities
src/process_lead.sh   parallel worker (check + score one lead)
src/output.sh         table, CSV, JSON
```

## Web app (run searches from the browser)

```bash
APP_PASSWORD=choose-a-password python3 server.py   # http://127.0.0.1:8080
```

Log in with `APP_USER` (default `admin`) / `APP_PASSWORD`. Opening `index.html` directly (without the server) still works as a read-only viewer.

## Docker (single container)

```bash
cp config.example.env .env      # set APP_PASSWORD (+ GOOGLE_PLACES_API_KEY)
docker compose up -d --build    # http://127.0.0.1:8080
docker compose logs -f
```

Results are saved to `./leads` on the host. CLI inside the container:
`docker compose exec leadfinder ./lead_finder.sh "Galle, Sri Lanka" "hotel" 20`

On a Linux host, if the container can't write to `./leads`, run `sudo chown -R 10001:10001 leads` (the container runs as a non-root user).

## Deploy on a VPS (Ubuntu/Debian)

```bash
# 1. Install and copy the project
sudo apt update && sudo apt install -y jq curl python3 nginx certbot python3-certbot-nginx
sudo useradd --system --create-home --shell /usr/sbin/nologin leadfinder
sudo mkdir -p /opt/lead-finder
# from your Mac:  rsync -av --exclude leads/ "lead gen/" user@VPS_IP:/tmp/lead-finder/
sudo cp -r /tmp/lead-finder/. /opt/lead-finder/
sudo chmod +x /opt/lead-finder/lead_finder.sh /opt/lead-finder/src/*.sh

# 2. Configure (set APP_PASSWORD, optional GOOGLE_PLACES_API_KEY)
sudo cp /opt/lead-finder/config.example.env /opt/lead-finder/.env
sudo nano /opt/lead-finder/.env
sudo chown -R leadfinder:leadfinder /opt/lead-finder && sudo chmod 600 /opt/lead-finder/.env

# 3. Service
sudo cp /opt/lead-finder/deploy/leadfinder.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now leadfinder

# 4. nginx + HTTPS (point your domain's DNS A record at the VPS first)
sudo cp /opt/lead-finder/deploy/nginx-leadfinder.conf /etc/nginx/sites-available/leadfinder
sudo sed -i 's/leads.example.com/YOUR_DOMAIN/' /etc/nginx/sites-available/leadfinder
sudo ln -s /etc/nginx/sites-available/leadfinder /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d YOUR_DOMAIN

# 5. Firewall
sudo ufw allow OpenSSH && sudo ufw allow 'Nginx Full' && sudo ufw enable
```

Logs: `journalctl -u leadfinder -f`. Always use HTTPS — the login is sent with every request.
