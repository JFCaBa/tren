# Andén · Próximo tren

The next Renfe Cercanías trains at your nearest station, with delays and the platform (vía).

- `app/`: Flutter app (iOS + Android)
- `pipeline/`: timetable feeds and the platform collector (`pipeline/vps/` runs on the VPS)
- `server/`: Andén API on the VPS (`api.whatplatform.uk/anden`)
- `web/`: privacy and support pages
- `tools/`: store assets (icons, screenshots)
- `docs/`: designs, plans, store notes

## Branches

- `main`: all code. Work happens here; a feature branch only while a feature is in progress.
- `platform-data`: **data, not code. Never delete, merge or rebase it.** The VPS collector writes
  the platform observations there every 15 minutes and the nightly feed reads them. See
  [docs/platform-data.md](docs/platform-data.md).
