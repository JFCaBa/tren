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
