# Andén /admin — plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** `https://api.whatplatform.uk/anden/admin` con personas al día, estaciones más vistas,
horas, versiones y seguimientos de Andén, solo con agregados.

**Architecture:** port de `platform/api/platform_api/{stats,stats_db,admin}.py` (repo JFCaBa/platform)
a `tren/server/anden_api/`, con el recuento hecho en el handler de `/live` en vez de por syslog.

**Tech Stack:** Python 3.12 stdlib + `tzdata`, SQLite, nginx.

**Spec:** `docs/superpowers/specs/2026-11-24-anden-admin-design.md`

## Global Constraints

- Nunca a disco ni a log: IP, User-Agent completo, hashes, clave del día. SQLite solo con columnas
  `day, visitors, people, requests, follows, hour, stop, version`.
- El recuento nunca rompe ni frena `/live` ni `/follow` (try/except, log `stats: <Class>`).
- Día y hora: `Europe/Madrid`.
- Solo cuenta UA que empieza por `Anden/` para personas; versión `^Anden/([0-9A-Za-z.+-]{1,16})`, si no `otro`.

## Review Focus

1. Cambio de día (medianoche Madrid) con peticiones llegando: personas del día cerrado correctas, sets y clave nuevos.
2. Reinicio a mitad de día: no se cuentan dos veces las personas ya guardadas (base congelada por día y por día+estación).
3. `X-Real-IP` ausente (petición directa al 8520): cuenta la petición, no una persona.
4. `/admin` sin cabecera secreta o con otra → 404; nunca cacheable.
5. Fallo de SQLite (disco lleno): `/live` sigue respondiendo; el lote pendiente se reintenta.

---

### Task 1: `stats.py` (Tally) + `stats_db.py`

**Produces:** `madrid_day(ts) -> str`, `madrid_hour(ts) -> int`,
`Delta(day, visitors, closed, requests, follows, hours, stations: dict[str, tuple[int, int]]  # stop → (people, requests), versions)`,
`Tally(key_factory)`: `.add_live(ts, stop, ip: str | None, ua: str)`, `.add_follow(ts)`,
`.visitors_today(now)`, `.drain(now) -> list[Delta]`.
`StatsDB(path)`: `.apply(deltas)`, `.visitors_base(day)`, `.days(since)`, `.top_stations(since, limit=20) -> list[(stop, people)]`
(personas sumadas por día, desempate por stop), `.hours(since)`, `.versions(since)`, `.stations_count(day)`,
`.backup(dir, day, keep=7)`, `.close()`.

- Port directo del de What Platform con: Madrid; sets por estación (`people` = tamaño del set del
  día de esa estación, absoluto; base congelada por (día, estación) al primer uso en el proceso,
  como `visitors`); persona solo si `ip` y UA `Anden/`.
- Tests portados de `platform/api/tests/test_stats.py` y `test_stats_db.py` adaptados, más:
  `test_station_people_distinct` (misma persona 10 veces en una estación = 1 persona, 10 peticiones;
  otra estación suma aparte), `test_station_people_restart_base`, `test_no_ip_counts_request_not_person`,
  `test_madrid_midnight` (23:59:59 y 00:00:00 Madrid en invierno/verano), `test_no_sensitive_columns`.

### Task 2: `admin.py` + rutas en `server.py`

**Produces:** `summary(db, today, rng, live_visitors, active_follows, names: dict[str, tuple[str, str]])`
(stop → (nombre, núcleo)), `render_page(s) -> str`; `make_server(..., stats=None, stats_db=None, admin_key="", station_names=None)`.

- Página en español (título «Andén · estadísticas»; «Personas hoy», «Estaciones hoy», «Trenes
  seguidos ahora / hoy», «Personas al día · últimos 30 días», filtro debajo, «Estaciones más
  vistas», «Horas punta», «Versiones de la app», pie «Cada persona cuenta una vez al día, sin
  guardar su IP. Hora de Madrid.»). Mismo CSS y SVG que What Platform; `escape` en todo.
- `GET /admin[?range=…]`: solo con `X-Admin-Key` igual a `admin_key` (`hmac.compare_digest`, clave
  no vacía) → 200 `text/html`, `Cache-Control: no-store`, CSP `default-src 'none'; style-src 'unsafe-inline'`;
  si no → 404.
- `/live`: tras responder 200 o 503, `stats.add_live(now, stop, X-Real-IP or None, UA)` en try/except.
  404 (estación desconocida) no cuenta.
- `POST /follow`: `upsert` devuelve `"ok"` (nuevo) / `"renewed"` (mismo tren) / `"busy"`; ambos
  primeros → 200; solo `"ok"` → `stats.add_follow(now)`.
- `StationTrips` guarda también `stop → (nombre, núcleo)` desde `index.json` `stops[]`
  (`name`, `nucleos[0]` → nombre del núcleo de `nucleos[]`): `names() -> dict`.
- `main`: `STATS_DB` (`/stats/stats.db`), `STATS_BACKUP_DIR` (`/stats/backups`), `ANDEN_ADMIN_KEY`;
  flusher cada 60 s (port de `run_flusher`, con dos pasadas al parar); SIGTERM vuelca antes de salir.
- `compose.yaml`: volumen `/opt/anden/stats:/stats`; `requirements.txt`: `tzdata==2025.2`.
- Tests: portados de `platform/api/tests/test_admin.py` (español) y `StatsServerTest`, más
  `test_live_counts_200_and_503_not_404`, `test_live_without_real_ip_no_person`,
  `test_follow_renewed_not_counted`, `test_admin_needs_key`, `test_names_from_index`.

### Task 3: nginx (repo `platform`) + privacidad

- `/anden/live/`: `proxy_set_header X-Real-IP $remote_addr;` (en vez de `""`), comentario de por qué.
- `location = /anden/admin { auth_basic "Andén"; auth_basic_user_file /etc/nginx/platform-admin.htpasswd;
  include /etc/nginx/anden-admin-key.conf; proxy_pass http://127.0.0.1:8520/admin$is_args$args; no-store; cabeceras }`.
- `web/privacidad.html`: sección «Estadísticas anónimas» (qué se cuenta, la IP + User-Agent se
  combinan un instante con una clave que se borra cada día, nunca se guardan); fecha.
- `server/README.md` y `deploy/README.md` (platform): pasos de la clave y del volumen.

### Task 4: deploy (sudo aprobado)

- `sudo install -d -o 10001 -g 10001 -m 750 /opt/anden/stats`.
- Clave: generar en el VPS sin mostrarla: `k=$(openssl rand -hex 32)`; añadir `ANDEN_ADMIN_KEY=$k` a
  `/opt/anden/.env` (con salto de línea) y `proxy_set_header X-Admin-Key "$k";` a
  `/etc/nginx/anden-admin-key.conf` (600 root).
- `git pull` + `docker compose up -d --build`; nginx copia + `nginx -t` + reload.
- Comprobar: `/anden/admin` sin contraseña → 401; directo al 8520 sin cabecera → 404; con cabecera
  (leída del .env en el VPS) → 200; tras unas peticiones a `/anden/live/18000` con UA `Anden/test`
  la página muestra Madrid Puerta de Atocha… y SQLite tiene filas.

## Cambios tras consenso del plan (24-11-2026; Codex + Agy)

- Reinicio a mitad de día: la base congelada garantiza que el total no baja ni repite lo ya
  guardado, pero quien vuelva tras el reinicio cuenta otra vez (no se guardan hashes: inevitable).
  Review Focus 2 queda así; los tests prueban monotonía, no deduplicación (Codex, Agy).
- La base por (día, estación) la resuelve `StatsDB.apply` (como `visitors`), nunca `Tally.add_live`:
  sin E/S en `/live` (Agy).
- Se conservan del port de What Platform: `Tally` con lock; SQLite WAL con `check_same_thread=False`
  y lock propio; `apply` en una sola transacción; el flusher guarda el lote hasta confirmarlo;
  `backup` crea el directorio. Tests de fallo de escritura y reintento sin duplicar (Codex, Agy).
- `nucleos` vacío o ausente en `index.json` → núcleo vacío (Agy).
- Logs: nginx ya tiene `access_log off` y `error_log /dev/null crit` en ese server; la API no
  registra peticiones. Se verifica en el deploy con peticiones de prueba (Codex).
- `/anden/admin/` con barra cae en `location / { return 404; }` de nginx: no llega a la API (Agy, sin cambio).
