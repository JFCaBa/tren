# Horarios de Andén en el VPS — plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** generar cada noche los horarios en el VPS y servirlos en
`https://api.whatplatform.uk/anden/data/…`; la app los pide ahí con reserva a GitHub Pages.

**Architecture:** cron de `ubuntu` → `pipeline/vps/feed.sh` → `build_feed.py` (sin cambios) en una
generación nueva `/opt/anden/data/gen.XXXXXX` → los ficheros iguales a los servidos se sustituyen por
enlaces duros a ellos (misma fecha → mismo ETag) → cambio atómico del enlace simbólico
`/opt/anden/data/current` → nginx lo sirve. (Consenso: rsync no publicaba de forma atómica.)

**Tech Stack:** bash, Python 3.12 stdlib (pipeline), nginx, Flutter/Dart (app).

**Spec:** `docs/superpowers/specs/2026-11-24-horarios-vps-design.md`

## Global Constraints

- `build_feed.py` no cambia; GitHub Pages y `feed.yml` siguen igual.
- Nunca dejar a medias ni vacío lo servido: si `build_feed.py` (o los tests) fallan, no se toca
  `current/`.
- Ficheros con el mismo contenido no se reescriben (fecha y ETag estables → 304 en la app).
- Sin log de peticiones en nginx; el log del cron no contiene datos de usuarios.
- `privacyUrl` sigue en `https://jfcaba.github.io/tren/privacidad.html`.

## Review Focus

1. Primera ejecución sin `current/` previo: debe usar Pages como publicación anterior (seed).
2. `build_feed.py` sale con 1 (Renfe caído, ningún núcleo válido): `current/` intacto, log dice el paso.
3. Un núcleo desaparece de la nueva salida: su fichero se borra de `current/` (si no, el índice
   nuevo y los ficheros no casan… el índice ya no lo lista, así que es basura inocua; se borra igual).
4. App: servidor caído o 5xx → Pages; ambos caídos → caché; 304 del servidor → caché sin ir a Pages.
5. nginx: rutas que no son `.json` dentro de `/anden/data/` → 404; nada fuera de `current/`.

---

### Task 1: `pipeline/vps/feed.sh` + test

**Files:** Create `pipeline/vps/feed.sh`, `pipeline/tests/test_vps_feed.py`. Modify `pipeline/vps/README.md`.

`feed.sh` (bash, `set -euo pipefail`), variables sobreescribibles para el test:
`SRC=${ANDEN_SRC:-$HOME/anden-platforms/src}`, `PLATFORMS=${ANDEN_PLATFORMS:-$HOME/anden-platforms/data/platforms.json}`,
`OUT=${ANDEN_DATA_DIR:-/opt/anden/data}`, `BUILD=${ANDEN_BUILD:-python3 $SRC/pipeline/build_feed.py}`
(el test lo sustituye por un falso), `SEED=${ANDEN_SEED:-https://jfcaba.github.io/tren}`.

Pasos: `exec 9>$OUT/lock; flock -n 9 || { echo "$(date -u +%FT%TZ) skipped: locked" >>$OUT/feed.log; exit 0; }`;
log a `$OUT/feed.log` con fecha (recorta > 1 MB como `collect.sh`); `trap` ERR que escribe
`error: <paso>`. Sin tests en el cron (se ejecutan en el paso de deploy; consenso).
`prev=file://$OUT/current` si existe `$OUT/current/index.json`, si no `$SEED`;
`gen=$(mktemp -d $OUT/gen.XXXXXX)` (borrado en `EXIT` salvo que se haya publicado);
`$BUILD --out $gen --platforms $PLATFORMS --previous-base $prev`; `test -s $gen/index.json`;
para cada fichero de `$gen` con igual contenido (`cmp -s`) que su par en `current/`: `ln -f` al de
`current/` (conserva inodo y fecha); `chmod -R a+rX $gen`; `ln -sfn $gen $OUT/current.new && mv -T $OUT/current.new $OUT/current`;
se borran las generaciones salvo la nueva y la anterior; línea `ok <n> núcleos`.

Tests (`unittest`, llaman a `bash feed.sh` con un `ANDEN_BUILD` falso en Python que escribe
ficheros dados o sale con 1, y registra su `--previous-base`):
- `test_first_run_seeds_from_pages`: sin `current` → `--previous-base` = SEED; `current/index.json` existe.
- `test_second_run_uses_current`: `--previous-base` = `file://<OUT>/current`.
- `test_unchanged_file_keeps_mtime`: mismo contenido dos veces → `st_mtime_ns` igual; cambiado → contenido nuevo.
- `test_build_failure_keeps_current`: falso sale 1 → `current` apunta a la misma generación, exit ≠ 0, log contiene `error`.
- `test_removed_nucleo_absent`: segunda salida sin `feeds/20.json` → no está en `current/`.
- `test_keeps_two_generations`: tras tres ejecuciones quedan 2 `gen.*`; ninguna sin publicar tras un fallo.
- `test_locked_logs_skip`: con el lock tomado → exit 0 y `skipped` en el log.
- `test_real_build_file_previous`: `build_feed.py` real con `--zip` de `tests/fixtures`, dos veces vía
  `feed.sh` (sin `ANDEN_BUILD`), para probar `file://` sobre el enlace `current` (reutiliza el zip/fecha de `test_cli_nucleos`).

README: sección «Nightly feed» (crear dir con sudo, cron `30 2 * * * $HOME/anden-platforms/src/pipeline/vps/feed.sh`, actualizar con `git pull`).

Run: `cd pipeline && python3 -m unittest discover -s tests` · Expected: todo OK.
Commit: `feat(vps): nightly feed build on the VPS`.

### Task 2: nginx (repo `platform`, `deploy/nginx/whatplatform.uk.conf`)

En el `server` de `api.whatplatform.uk`, antes de `location /`:
```
location ~ "^/anden/data/((?:feeds/[0-9A-Za-z_/-]+|index|feed)\.json)$" {
    limit_except GET { deny all; }
    access_log off;
    alias /opt/anden/data/current/$1;
    default_type application/json;
    gzip on; gzip_types application/json;
    add_header Cache-Control "public, max-age=600";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
}
```
Y además `location ^~ /anden/data/ { access_log off; return 404; }` no: `^~` ganaría al regex.
Se usa `location /anden/data/ { access_log off; return 404; }` (prefijo normal: el regex gana si
encaja). Consenso. `..` imposible por el regex (sin `.` salvo `.json`). Commit en `platform`: `feat(nginx): serve Andén timetables`.

### Task 3: app — servidor con reserva a Pages

**Files:** Modify `app/lib/config.dart`, `app/lib/data/json_cache.dart`, `app/test/support.dart`,
`app/test/json_cache_test.dart`.

- `config.dart`: `const pagesUrl = 'https://jfcaba.github.io/tren';` (`privacyUrl` = `$pagesUrl/privacidad.html`),
  `const dataUrl = 'https://api.whatplatform.uk/anden/data';`; se quita `baseUrl`.
- `JsonCache`: nuevo `final String? fallbackUrl`. En `_refresh`: si la petición a `url` lanza, da
  ≠ 200/304 o el cuerpo no se puede parsear, se prueba `fallbackUrl` (mismo `If-None-Match`, mismo
  `timeout`) antes de caer a la caché. Un 404 también pasa a Pages: index.json ya no lista un núcleo
  borrado, así que un 404 del servidor es un fallo nuestro, no un borrado.
  `indexCache`/`nucleoCache` usan `dataUrl` como `url` y `pagesUrl` como `fallbackUrl` (misma ruta relativa).
- `FakeServer` acepta las dos raíces (`/tren/` y `/anden/data/`), registra el host y tiene
  `serverFails` (falla `api.whatplatform.uk`).
- Tests nuevos en `json_cache_test.dart`:
  - `primary first`: pide `https://api.whatplatform.uk/anden/data/index.json`, una sola petición.
  - `server down → pages`: `serverFails` → devuelve el feed de Pages.
  - `server 500 → pages`.
  - `server bad json → pages`.
  - `both down with cache → cache`.
  - `304 from server → cache, no pages request`.
  - Las URLs esperadas existentes (`feeds/40.json`, `feeds/v3/40.json`, `index.json`) pasan a la raíz nueva.
- `home_screen_test` (privacidad en Pages) sigue igual.

Run: `cd app && flutter test && flutter analyze` · Expected: todo verde, sin avisos.
Commit: `feat(app): timetables from our server, GitHub Pages as fallback`.

### Task 4: deploy (sudo aprobado)

- `sudo install -d -o ubuntu -g ubuntu -m 755 /opt/anden/data`.
- `git -C ~/anden-platforms/src pull --ff-only`; tests del pipeline allí (`python3 -m unittest discover -s tests`); primera ejecución a mano de `feed.sh`; comprobar
  `current/` igual en contenido que Pages (`cmp` de `index.json` tras normalizar o mismo nº de núcleos).
- Cron `ubuntu`: `30 2 * * * $HOME/anden-platforms/src/pipeline/vps/feed.sh`.
- nginx: copia previa, `git pull` en `/opt/platform/repo`, `cp` conf, `nginx -t`, reload.
- Comprobar: `curl -sI .../anden/data/index.json` → 200, `content-type: application/json`, ETag;
  con `If-None-Match` → 304; `.../anden/data/x.txt` → 404; `Accept-Encoding: gzip` → `content-encoding: gzip`.
- La app no se compila aquí: va en la próxima build.

## Consenso del plan (24-11-2026)

- Codex: publicación atómica (generaciones + enlace simbólico) → aplicado. 404 para el resto de `/anden/data/` → aplicado (también Agy).
- Agy: sin tests en el cron → aplicado; aviso en log si hay lock → aplicado; ETag también a Pages → aplicado.
- Agy, no aplicados (decisión de Claude): fallback solo en 5xx (un 404 aquí es fallo nuestro); dos
  generadores (VPS y Actions) a la vez es temporal: Pages se retira cuando la nueva app esté adoptada;
  timeout doble: con caché la app ya muestra lo guardado mientras refresca; `file://` ya lo cubren
  `test_cli_nucleos` y se añade `test_real_build_file_previous`.
- opencode: sin hallazgos.
