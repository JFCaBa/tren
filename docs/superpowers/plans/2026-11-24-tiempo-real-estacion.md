# Tiempo real por estación — plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** `GET https://api.whatplatform.uk/anden/live/<estación>` devuelve retrasos y vías de los
trenes de esa estación; la app lo usa cada 30 s y vuelve a Renfe directo si falla.

**Architecture:** la API de Andén (`server/anden_api`, Python stdlib, puerto 8520) ya lee Renfe con
`renfe.Feed` (caché 20 s). Nuevo `stations.py` con el índice estación→trenes desde los horarios del
VPS; nueva ruta en `server.py`; nginx la publica. En la app, `StationLiveClient` alimenta los
mismos `RtSnapshot`/`PlatformSnapshot` de hoy.

**Tech Stack:** Python 3.12 stdlib + pytest (server), nginx, Flutter/Dart (app).

**Spec:** `docs/superpowers/specs/2026-11-24-tiempo-real-estacion-design.md`

## Global Constraints

- Sin log de peticiones (ni en la API ni en nginx); el log de la API solo nombra clases de error.
- Seguimiento (`/follow`, `/train`, poller) sin cambios de comportamiento.
- Si el servidor no responde 200 válido, la app hace exactamente lo de hoy (Renfe directo).
- Ids: estación `[0-9A-Za-z_-]{3,12}` (como `STOP_RE`).

## Review Focus

1. Horarios aún no generados/montados al arrancar → 503, y se cargan en cuanto aparecen.
2. Recarga nocturna: el cambio de generación se recoge sin reiniciar; un feed roto deja el índice anterior.
3. Renfe congelado (> 5 min) o caído → 503 en el servidor → la app va a Renfe directo.
4. App: respuesta del servidor con forma inesperada → Renfe directo, nunca un tablero vacío "en vivo".
5. Una estación con muchos trenes (Atocha) → respuesta pequeña y rápida (sin recorrer los feeds por petición).

---

### Task 1: índice estación → trenes (`server/anden_api/stations.py`)

**Interfaces — Produces:** `class StationTrips(root: Path, clock=time.monotonic, every: float = 60.0)`,
`.get(stop_id: str) -> frozenset[str] | None` (None = sin índice cargado; estación desconocida →
`frozenset()`), `.known(stop_id) -> bool`, `.loaded -> bool`.

- Lee `root/index.json` → `nucleos[].feed`, cada `root/<feed>` → `trips[].id` y `trips[].times[][0]`.
- Recarga si `os.path.realpath(root)` cambió desde la última carga, como mucho cada `every` s
  (comprobación perezosa en `get`, con lock). Error de lectura/JSON → conserva el índice anterior.

Tests `server/tests/test_stations.py` (pytest, `tmp_path`, generaciones `gen.a`/`gen.b` y enlace `current`):
- `test_index_from_feeds`: dos núcleos; `get("S1") == {"T1","T2"}`; `known("NOPE") is False`.
- `test_not_loaded_returns_none`: sin `current` → `get` es None, `loaded` False; al crearlo y pasar `every` → cargado.
- `test_reload_on_new_generation`: cambiar `current` a `gen.b` y avanzar el reloj → índice nuevo; sin avanzar → el viejo.
- `test_broken_generation_keeps_previous`: `gen.b` con feed JSON roto → sigue el índice de `gen.a`.

### Task 2: lectura por estación (`renfe.py`, `server.py`)

**Interfaces — Consumes:** `StationTrips`. **Produces:** `Feed.timestamp -> int | None` (ts del último
feed bueno), `Sighting.at: int | None = None` (vehicle.timestamp), `station_reading(trips, trips_ts,
positions, positions_ts, trip_ids, stop) -> dict`, ruta `GET /live/<stop>`, `make_server(..., stations=None)`.

- `station_reading`: forma del spec; `trips` = Renfe ∩ `trip_ids`; `platforms` = sightings con
  `stop_id == stop` y `platform` no nulo (`at` = `Sighting.at` o `positions_ts`).
- Ruta: `stations` None o no cargado → 503; `trips.fetch(now)` None → 503; estación desconocida →
  404; si no 200 con `station_reading`. Positions None → `positionsAt: null, platforms: {}`.
- `main`: `StationTrips(Path(env.get("ANDEN_DATA", "/opt/anden/data/current")))`.
- `compose.yaml`: `- /opt/anden/data:/opt/anden/data:ro`.

Tests (`test_renfe.py`, `test_server.py`):
- `test_positions_keep_vehicle_timestamp`.
- `test_feed_timestamp`.
- `test_station_reading_filters_trips_and_platforms`: tren de otra estación y vía de otra parada fuera.
- `test_live_ok`, `test_live_503_without_index`, `test_live_503_when_renfe_down`, `test_live_404_unknown_station`,
  `test_live_bad_id_404` (`/live/a`), `test_live_not_logged` (log vacío).
- Los tests existentes de `/train` y `/follow` siguen verdes.

Run: `cd server && python -m pytest -q tests` · Expected: todo verde.

### Task 3: nginx (repo `platform`)

```
limit_req_zone $binary_remote_addr zone=anden_live:1m rate=30r/m;
location ~ "^/anden/live/([0-9A-Za-z_-]{3,12})$" {
    limit_except GET { deny all; }
    limit_req zone=anden_live burst=20 nodelay;
    limit_req_status 429;
    set $stop $1;
    proxy_pass http://127.0.0.1:8520/live/$stop;
    (cabeceras proxy, timeouts 2 s / 15 s, no-store, HSTS, nosniff como /anden/train)
}
```

### Task 4: app

**Files:** Create `app/lib/data/station_live.dart`, `app/test/station_live_test.dart`. Modify
`app/lib/config.dart`, `app/lib/app_controller.dart`, `app/lib/main.dart` (o donde se construye el
controlador), `app/test/support.dart`, `app/test/app_controller_test.dart`, `web/privacidad.html`.

**Produces:** `typedef StationLive = ({RtSnapshot rt, PlatformSnapshot? positions});`
`StationLiveClient(http.Client, {String baseUrl = apiBaseUrl, DateTime Function()? now})`,
`Future<StationLive> fetch(String stopId)` (timeout 10 s; ≠ 200 o forma inválida → lanza).
`parseStationLive(Map json, DateTime fetchedAt) -> StationLive`.

- `AppController(..., StationLiveClient? live)`. En `_pollRt`: con estación y `live` → intenta
  `live.fetch(station.id)`; bien → `rt` y, si trae `positionsAt`, `positions` (mismo filtro de
  respuestas fuera de orden) + `_rememberPlatforms`; falla → el camino actual (Renfe rt + positions
  cuando toca). Alertas igual.
- Tests `station_live_test.dart`: parse ok (trips, platforms con `at`), `positionsAt` null →
  positions null, 500 → lanza, `trips` no mapa → lanza, URL `.../anden/live/18000`.
- Tests controlador: con live ok no hay peticiones a `gtfsrt.renfe.com` trip_updates/positions;
  live falla → `rtCalls == 1` (Renfe directo) y tablero en vivo; vía de live se muestra.
- `privacidad.html`: tiempo real de la estación desde `api.whatplatform.uk` (ve la estación, no se
  registra) y Renfe si no responde; fecha nueva.

Run: `cd app && flutter test && flutter analyze` · Expected: verde, sin avisos.

### Task 5: deploy (sudo aprobado; tras consenso del diff)

- Commits, merge a main, push (tren y platform).
- VPS: `/opt/anden/repo` `sudo git pull`; `sudo docker compose up -d --build` en `server/`; logs.
- nginx: copia previa, `git pull` en `/opt/platform/repo`, `cp`, `nginx -t`, reload.
- Comprobar: `curl -A Anden/1.4 https://api.whatplatform.uk/anden/live/18000` → 200 JSON pequeño con
  `tripsAt` reciente; `/anden/live/zzz` → 404; `/anden/train/...` y `/anden/health` siguen 200.

## Cambios tras consenso del plan (24-11-2026; Codex + Agy, opencode sin clave)

Sustituyen a lo anterior donde choquen:

- **La petición nunca espera a Renfe** (Codex: positions lento bloqueaba; Agy: parseo bajo lock).
  `Feed.cached(now)` devuelve lo último bueno y fresco sin descargar. Nuevo
  `anden_api/refresher.py`: `Refresher(trips, positions, stations, clock, every=5.0, demand=120.0)`
  con `.touch(now)` (marca demanda y despierta el hilo si no hay datos) y `.run(stop: Event)`: cada
  `every` s, si hubo demanda en los últimos `demand` s, `trips.fetch(now)` y `positions.fetch(now)`
  (la caché de 20 s de `Feed` evita duplicar con el poller), y siempre `stations.refresh()`.
  Ruta: `refresher.touch(now)`; `trips.cached(now)` None → 503 (la primera petición tras un rato
  sin uso va a Renfe directo; la siguiente ya sale del servidor). Renfe congelado > 5 min ya da None
  (`MAX_AGE`); se añade `test_live_503_when_renfe_frozen`.
- **StationTrips:** `refresh()` (no `get`) carga; resuelve `realpath(root)` una vez y lee
  `index.json` y todos los feeds de esa generación; publica el índice nuevo de una vez solo si todo
  fue bien. `get()` solo lee la referencia (sin lock, sin E/S). `main` llama a `refresh()` al arrancar.
  Sin la comprobación previa de `loaded` en la ruta: `get()` None → 503 (Agy).
- **App:** la respuesta se asocia a la estación pedida; si al volver la estación es otra, se
  descarta. Al cambiar de estación, un `rt`/`positions` que vino del servidor (de otra estación) se
  olvida. Test con cambio de estación a mitad de petición (Codex). Timeout del cliente 5 s (Agy).
- **nginx:** `access_log off;` explícito; límite `rate=300r/m burst=100` por los CGNAT de los
  operadores móviles (Agy).
