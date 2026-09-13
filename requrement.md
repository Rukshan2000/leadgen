Build a complete, locally runnable business-lead research tool using Bash (`.sh`) as the main launcher.

### Goal

I want to find businesses that are likely to need a professional website, especially businesses such as:

* Hotels / villas / guesthouses
* Private clinics
* Dental clinics
* Construction companies
* Real-estate companies
* Vehicle rental companies
* Wedding/event businesses
* Tuition/education institutes
* Photographers
* Gyms/fitness centers
* Salons/beauty businesses
* Restaurants
* Lawyers
* Accounting firms
* Manufacturers
* Import/export businesses
* Other local service businesses

The tool should help me identify businesses that have an online presence but appear to have no proper website or have a weak/outdated website.

### Requirements

1. Create a main executable:
   `lead_finder.sh`

2. It must run locally from the terminal:
   `./lead_finder.sh`

3. Ask the user interactively for:

   * Location/city
   * Business category
   * Number of leads wanted

4. Search for publicly available business information using legitimate/public sources or APIs. Do NOT scrape sites in ways that violate their terms or bypass anti-bot protections.

5. For every business found, collect whatever publicly available information is legitimately accessible, such as:

   * Business name
   * Category
   * Location
   * Website
   * Phone
   * Public email, if available
   * Google/business profile URL or source URL
   * Social media URL, if publicly available

6. Determine a `website_status`:

   * `NO_WEBSITE`
   * `HAS_WEBSITE`
   * `WEAK_WEBSITE`
   * `UNKNOWN`

7. Create a lead score from 0–100.

Example scoring:

* No website: +40
* Website appears outdated/poor quality: +20
* Active social media but no website: +15
* Many reviews/public presence: +10
* Business category strongly benefits from a website: +10
* Public contact information available: +5

8. Output results in:

   * Terminal table
   * CSV file
   * JSON file

9. Save results automatically into:
   `./leads/YYYY-MM-DD/`

10. Prevent duplicate businesses.

11. Include error handling, API-rate-limit handling, retries where appropriate, and clear messages when an API key is missing.

12. Never fabricate business information.

### Optional website-quality check

If a business has a website, perform a lightweight public HTTP check and report things such as:

* HTTP status
* HTTPS available
* Page title
* Whether the site is reachable
* Basic signs of an outdated/poor site

Do not attempt unauthorized vulnerability scanning or exploitation.

### Configuration

Create:

`config.example.env`

with placeholders for any required API keys.

The user should be able to create:

`.env`

and put their API credentials there.

Do not hard-code API keys.

### Project structure

Create something similar to:

lead-finder/
├── lead_finder.sh
├── src/
│   ├── search.sh
│   ├── scoring.sh
│   ├── website_check.sh
│   └── output.sh
├── leads/
├── config.example.env
├── .gitignore
└── README.md

Make the shell script portable where practical and clearly do
