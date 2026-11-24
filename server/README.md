# Andén follow API

iPhones register the one train they follow (`POST /follow`, `DELETE /follow`); a poller reads
Renfe's open GTFS-RT feeds (trip updates and vehicle positions) every 30 s and sends alerts and
Live Activity updates through APNs. Port of What Platform's API (repo JFCaBa/platform, `api/`).
Tokens live in memory only and are never logged; requests are not logged.

GET /live/<estación> gives the delays and live platforms of that station's trains (the app's
board), from the timetables in `/opt/anden/data/current` (pipeline/vps/feed.sh) and Renfe's feeds,
read in the background only while someone is asking.

Public URL: `https://api.whatplatform.uk/anden/follow` (nginx location in the platform repo,
`deploy/nginx/whatplatform.uk.conf`, proxies to 127.0.0.1:8520).

Tests: `python -m pytest -q tests` (needs `requirements.txt` + pytest).

Deploy on the VPS (`ssh myairports`):

```sh
sudo git clone https://github.com/JFCaBa/tren.git /opt/anden/repo      # first time
sudo install -m 600 /dev/null /opt/anden/.env                          # first time: APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID
cd /opt/anden/repo && sudo git pull --ff-only
cd server && sudo docker compose up -d --build && sudo docker compose logs --tail 5
```

The APNs values are the team key's, the same as What Platform's `/opt/platform/.env`.

## Stats (`/anden/admin`)

`GET /live/<stop>` and new iPhone follows are counted in memory (`stats.py`) and flushed every
minute to `/opt/anden/stats/stats.db` (aggregates only; daily copies in `backups/`, 7 kept).
People are counted once a Madrid day with an HMAC of IP + app version under a key that lives only
in memory; nginx sends the IP on `/anden/live/` only. The page is
`https://api.whatplatform.uk/anden/admin`: nginx asks for the What Platform admin password
(`/etc/nginx/platform-admin.htpasswd`) and adds `X-Admin-Key` from
`/etc/nginx/anden-admin-key.conf`, which must equal `ANDEN_ADMIN_KEY` in `/opt/anden/.env`.

Setup (once, on the VPS):

```sh
sudo install -d -o 10001 -g 10001 -m 750 /opt/anden/stats
k=$(openssl rand -hex 32)
printf '\nANDEN_ADMIN_KEY=%s\n' "$k" | sudo tee -a /opt/anden/.env >/dev/null
sudo install -m 600 /dev/null /etc/nginx/anden-admin-key.conf   # private before the key goes in
printf 'proxy_set_header X-Admin-Key "%s";\n' "$k" | sudo tee /etc/nginx/anden-admin-key.conf >/dev/null
unset k
```
