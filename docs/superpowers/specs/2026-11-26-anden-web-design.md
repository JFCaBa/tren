# Andén website at andenapp.com — design

Approved shape (user, 26-11-2026): "como What Platform": live departures and one page per station,
the board built on the server. The domain andenapp.com is bought by the user (Cloudflare
Registrar); DNS is set up by Claude in Cloudflare when the user says so.

## Why

Andén only has two legal pages on GitHub Pages. A public website with every Cercanías/Rodalies
station's live board brings people from searches ("andén tren Xàtiva", "próximo tren Atocha") and
from there to the app, as whatplatform.uk does for What Platform.

## Goals

- `andenapp.com`: home with station search, nearest station (only if the browser grants location)
  and popular stations by núcleo.
- `andenapp.com/estacion/{stopId}`: next trains like the app's board: line with its colour,
  destination, time, delay or "Cancelado", platform (live from Renfe, else the usual learned one,
  marked as usual). Refreshes every 30 s. Tapping a train shows its remaining stops.
- Crawlable like whatplatform.uk: one pre-rendered static page per station (title, description,
  canonical, Open Graph, JSON-LD `TrainStation` with geo, heading, nearby stations), an A–Z page,
  `sitemap.xml`, `robots.txt`; registered in Google Search Console and Bing.
- Favicons and App Store badge (Google Play badge only if the Play listing is public; check).
- `andenapp.com/privacidad` and `andenapp.com/ayuda` (same content as web/privacidad.html and
  web/soporte.html).

## Non-goals

- No "voy a…" destination filter, no following a train, no alerts, no accounts: those stay in the app.
- Spanish only (no Catalan/Basque/English).
- The store listings' privacy/support URLs are not changed now; GitHub Pages keeps serving the old
  pages so those links never break.

## Anti-goals

- Storing or logging anything personal: same rules as the API (no IPs, User-Agents or hashes on
  disk or in logs; people counted once a day with the in-memory daily key).
- A web board that disagrees with the app's board for the same station and moment.
- Unknown stations answering 200 (soft 404s), as fixed for whatplatform.uk.
- A framework, bundler or build step for the browser code.

## Approaches considered

1. **Server builds the board (chosen).** New `GET /board/<stop>` in the Andén API (tren repo
   `server/anden_api`), a Python port of `app/lib/domain/board.dart`'s `computeBoard`, using the
   nightly timetables it already reads (`/opt/anden/data/current`) and the Renfe real time it
   already holds. The page fetches a few KB. Same architecture as What Platform.
2. Browser downloads the núcleo feed (Madrid ≈ 900 KB gzip) and ports the board to JS: rejected,
   too heavy on mobile and for Google rendering.
3. Nightly per-station timetable files + `/anden/live` + JS board: rejected, still a JS port of the
   board plus thousands of files a night.

## Decisions

- **Code lives in the tren repo**, mirroring the platform repo: `website/` for the static site
  (ES modules, no build, like platform `site/`), `website/build_pages.py` + tests for the
  crawlable pages, nginx config for andenapp.com under `pipeline/vps/` beside the other VPS files.
  Reuse platform's patterns (build_pages.py symlink swap, extraBelongs, setMeta, 404 shell)
  by copying and adapting, not by sharing code across repos.
- **Same origin, no CORS (Claude's call):** andenapp.com proxies `/api/board/<stop>` to the
  Andén API on 127.0.0.1:8520, with its own rate limit like `/anden/live`. Also reachable as
  `api.whatplatform.uk/anden/board/<stop>` for a future app use.
- **Board response:** for one stop, the next 8 departures by estimated time, each with trip id,
  line, colour, destination, scheduled and estimated times (ISO, Europe/Madrid), delay seconds or
  null, live, cancelled, minutes, usual platform, live platform (only within 15 min, as the app),
  and remaining stops (id, name, time); plus `rtStale`, `feedStale`, `feedCoversToday`,
  `generatedAt`, station name and its núcleo(s). Same constants as board.dart (real time max age
  2 min, feed max age 3 days, 60 s grace after departure, service days -1/0/+1 with GTFS
  "noon minus 12 h" times). Tests port board.dart's own test cases so both agree.
- **Stats:** web requests to `/board` count in `/anden/admin` as version "web" (browser
  User-Agents; bots excluded), like What Platform does; the app's `/live` counting is unchanged.
- **Station list for pages and search:** the stops in `index.json` / núcleo feeds of the current
  generation. URL key is Renfe's stop id (`/estacion/65000`), the name goes in title and heading.
  nginx serves `/estacion/<id>` only for ids with a built page, else 404 with the JS shell.
- **When pages are built:** after the nightly feed (`pipeline/vps/feed.sh`, 02:30 UTC) and on
  deploy; atomic symlink swap, keeps the previous build, refuses with too few stations.
- **Legal pages:** rendered from `web/*.html` with `pipeline/render_pages.py` on the VPS too; the
  contact name/email come from an env file on the VPS (never in the repo).
- **Domain/TLS:** Cloudflare DNS `A` records for `andenapp.com` and `www` to the VPS, DNS only
  (no proxy); certificate on the VPS with certbot as for whatplatform.uk; `www` redirects to the
  apex; same security headers (CSP, HSTS, nosniff, frame DENY, no-referrer).

## Calls after the builder check (Claude's, 26-11-2026)

- **Scope includes the rollout**, as for whatplatform.uk: API deploy, pages, nginx + certificate,
  DNS in Cloudflare (when the user says), then Search Console and Bing. Sudo on the VPS was
  approved by the user earlier; cron jobs run as `ubuntu`, so pages go to a directory it owns
  (`/opt/anden/pages`).
- **No `api.whatplatform.uk/anden/board` route** for now (YAGNI); the platform repo's nginx is not
  touched. The andenapp.com conf defines its own rate-limit zone.
- **Stats like What Platform's stats.py:** `/board` gets the client IP from nginx (as `/live`); a
  browser (`Mozilla/…`) that is not a bot, crawler, link preview or headless tool counts as
  version «web» in the same people-per-day and per-station counts; app counting is unchanged.
- **`/board` always answers 200** for a known station: scheduled times with `rtStale: true` when
  real time is not fresh, and it wakes the refresher, so the next 30 s refresh is usually live.
  404 for an unknown station, 503 only when no timetable generation is loaded.
- **Stations in several núcleos:** the board merges the trips of every núcleo the stop lists, as
  the app does. 887 stops, no repeated names: one page per stop id, no merging. No container
  memory limit is set; parsed feeds are loaded once per generation and the old one dropped.
- **No nginx cache for `/board`:** the API keeps each stop's computed board for 15 s in memory, so
  many viewers of one station cost one computation and every request is still counted.

## Left to the builder

- Exact markup/CSS (Andén's teal brand `#0F766E`, light/dark), copy texts in Spanish.
- How popular stations per núcleo are chosen (a fixed list is fine).
- How the board endpoint caches parsed feeds (once per generation, like `stations.py`).
- Whether Andén's Play listing is public (badge or not).
