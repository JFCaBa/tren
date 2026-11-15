# Próximo Tren (Cercanías Valencia C1/C2): plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir una app Flutter (iOS y Android) que al abrirse muestre los minutos que faltan para los 3 próximos trenes de C1/C2 en cada sentido, en la estación más cercana. Usa un horario filtrado que una GitHub Action publica cada noche, más los retrasos en tiempo real de Renfe.

**Architecture:** Un script Python sin dependencias (`pipeline/`) descarga el GTFS de Renfe, filtra C1/C2 de Valencia y genera `feed.json`. Una GitHub Action lo ejecuta cada noche y lo publica en GitHub Pages. La app (`app/`) descarga ese JSON (con caché en disco) y consulta `trip_updates.json` de Renfe cada 30 s. Una función pura combina ambos y produce la pantalla.

**Tech Stack:** Python 3.9+ (solo stdlib, tests con `unittest`), GitHub Actions + Pages, Flutter 3.50 / Dart, con los paquetes `http`, `path_provider`, `geolocator`, `timezone` y `shared_preferences`.

**Spec:** `docs/superpowers/specs/2026-11-15-cercanias-valencia-design.md`

## Global Constraints

- Solo líneas C1 y C2 de Valencia: `route_id` empieza por `40T` y `route_short_name` ∈ {`C1`, `C2`}. Todos los campos GTFS se limpian con `strip()`.
- GTFS estático: `https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip`. RT: `https://gtfsrt.renfe.com/trip_updates.json`.
- URL del feed publicado: `https://jfcaba.github.io/tren/feed.json` (repo público `JFCaBa/tren`).
- Zona horaria: siempre `Europe/Madrid`. Las horas GTFS ≥ 24:00 pertenecen al día de servicio anterior.
- "En vivo" = el `trip_id` está en un RT descargado hace < 2 min, cuyo `header.timestamp` también tiene < 2 min, y trae `tripUpdate.delay`. RT de más de 2 min → todo "previsto" y aviso "sin tiempo real".
- Aviso de horario viejo: el feed no cubre la fecha de hoy, o `generated_at` tiene > 3 días. Se refresca al abrir si el cacheado no es de hoy o tiene > 12 h.
- RT: cada 30 s en primer plano, con timeout de 10 s.
- La validación del pipeline falla si falta C1 o C2, si hay < 20 paradas o si no cubre hoy y mañana.
- 3 trenes por sentido, mezclando C1 y C2. Los trenes que terminan antes del final de la línea se muestran con su destino real.
- Colores: C1 `#7AB3DE`, C2 `#F79529`. Texto "Datos: Renfe" visible. UI en español, con modo claro/oscuro del sistema.
- Permiso de ubicación solo "mientras se usa".
- Nombre de la app: "Próximo Tren". Bundle id / applicationId: `com.jfcaba.proximotren`. Sin marcas de Renfe en el nombre ni en el icono.
- Keystores, certificados, `key.properties` y perfiles de firma **nunca** van al repo (`.gitignore`).
- Regla del usuario: antes de **cada** `git commit` se valida el diff con la skill `consenso`, salvo los cambios triviales.

## Review Focus

1. **La estación del usuario es la última parada del tren** (por ejemplo, en València Nord los trenes que llegan y terminan ahí). No deben salir en la lista. Test: `test_excludes_trips_terminating_at_stop` (Task 5).
2. **Pasada la medianoche**: un viaje del día de servicio de ayer con hora `24:30:00` debe aparecer hoy a las 00:30. Test: `test_includes_previous_service_day_after_midnight` (Task 5).
3. **Retraso negativo (tren adelantado)**: el tiempo estimado es menor que el previsto y se muestra "−3". Test: `test_negative_delay` (Task 5).
4. **Primer arranque sin red y sin caché**: mensaje claro con botón de reintentar, nunca pantalla en blanco ni cuelgue. Test: `test_first_launch_offline_reports_error` (Task 6).
5. **Permiso de ubicación denegado**: se abre el selector de estación y se recuerda la última elegida. Test: `test_location_denied_uses_saved_station` (Task 7).

---

### Task 1: Pipeline: parseo, filtrado y JSON

**Files:**
- Create: `.gitignore`, `pipeline/build_feed.py`, `pipeline/tests/__init__.py`, `pipeline/tests/test_build_feed.py`
- Create: `pipeline/tests/fixtures/mini/{routes,trips,stop_times,stops,calendar}.txt`

**Interfaces:**
- Produces: `build_feed(gtfs_dir: Path, today: date, days: int = 7) -> dict`, que devuelve el esquema `feed.json` v1:
  ```json
  {"version": 1, "generated_at": "2026-11-15T03:00:00Z",
   "valid_from": "2026-11-14", "valid_to": "2026-11-22",
   "stops": [{"id": "65000", "name": "València-Estació del Nord", "lat": 39.46, "lon": -0.37, "lines": ["C1","C2"]}],
   "trips": [{"id": "4018D24077C2", "line": "C2", "dir": "out", "dest": "Moixent",
              "dates": ["2026-11-15"], "times": [["65000", 67200], ["64200", 68100]]}]}
  ```
  - `valid_from` = `today − 1 día` (para los viajes ≥ 24:00 de ayer), `valid_to` = `today + days`, ambos incluidos.
  - Los viajes con alguna hora ≥ `48:00:00` se descartan y se imprime un aviso en stderr. Si un `trip_id` sale con más de una fecha, también se avisa (sin fallar): hoy no pasa, porque cada viaje de Valencia circula una sola fecha.
  - `times`: `[stop_id, segundos desde la medianoche del día de servicio]`, ordenados por `stop_sequence`. Se usa la hora de salida (`departure_time`) y, si falta, la de llegada.
  - `dir`: `"in"` si la última parada está más cerca (distancia haversine) de València Nord (`65000`) que la primera. Si no, `"out"`.
  - `dest`: nombre de la última parada.
  - `dates`: fechas del calendario de ese `service_id` dentro de la ventana, tomadas de `calendar.txt` (días de la semana + rango) y de `calendar_dates.txt` si existe. Viajes sin fechas en la ventana → se descartan.
  - `stops`: solo las paradas que usan los viajes incluidos, con sus líneas.
- `stop_times.txt` (~270 MB) se lee en streaming con `csv`, descartando las filas de viajes no filtrados.

- [ ] **Step 1: Crear la fixture `mini`.** Rutas: `40T0001C1` (C1), `40T0005C2` (C2), `10T0001C1` (C1 de Madrid, debe descartarse), `40T0007C3` (C3, debe descartarse). Paradas: `65000` València Nord, `64200` Silla, `69110` Gandia, `64203` (intermedia C2), `99999` (Madrid). Viajes: un C1 de salida (65000→64200→69110); un C1 de entrada que acaba en 65000; un C2 corto que acaba en Silla; un viaje con hora `24:30:00`; un viaje de Madrid. `calendar.txt` con un servicio solo para `20261115` y otro de lunes a domingo `20261101–20261130`. Las columnas llevan espacios de relleno, como el fichero real.
- [ ] **Step 2: Escribir los tests que fallan** en `test_build_feed.py` (`unittest`):
  - `test_filters_only_valencia_c1_c2`: los ids de los viajes no incluyen el de Madrid ni el de C3.
  - `test_direction_and_dest`: C1 de salida → `dir=="out"`, `dest=="Gandia"`. C1 de entrada → `dir=="in"`. C2 corto → `dest=="Silla"`.
  - `test_times_seconds_past_24h`: el viaje `24:30:00` tiene `88200`.
  - `test_dates_within_window`: con `today=date(2026,11,15)`, el servicio de un solo día da `["2026-11-15"]` y el semanal da 9 fechas (del 14 al 22, ambas incluidas), dentro de `valid_from`/`valid_to`.
  - `test_fields_are_stripped`: ningún id ni nombre tiene espacios.
  - `test_drops_trips_beyond_48h`: un viaje de la fixture con `48:10:00` no aparece.
- [ ] **Step 3: Ejecutar** `cd pipeline && python3 -m unittest -v`. Debe FALLAR (no existe `build_feed`).
- [ ] **Step 4: Implementar `build_feed`** en `pipeline/build_feed.py`.
- [ ] **Step 5: Ejecutar** `cd pipeline && python3 -m unittest -v`. Deben PASAR los 6 tests.
- [ ] **Step 6: `git init`** en la raíz. Crear `.gitignore` con `*.jks`, `*.keystore`, `key.properties`, `*.mobileprovision`, `*.p12`, `build/`, `.dart_tool/`, `__pycache__/`, `pipeline/out/`, `.consenso/`. Validar con `consenso` y hacer commit: `feat(pipeline): build C1/C2 feed from Renfe GTFS`.

### Task 2: Pipeline: validación, CLI y prueba con datos reales

**Files:**
- Modify: `pipeline/build_feed.py`
- Test: `pipeline/tests/test_build_feed.py`

**Interfaces:**
- Consumes: `build_feed` (Task 1).
- Produces: `validate_feed(feed: dict, today: date) -> list[str]` (lista de errores; vacía = válido). CLI: `python3 build_feed.py --out DIR [--zip PATH]`. Descarga el zip (o usa `--zip`), escribe `DIR/feed.json` y sale con código 1 si `validate_feed` devuelve errores, sin escribir nada en ese caso.

- [ ] **Step 1: Escribir los tests que fallan:**
  - `test_validate_ok`: el feed de la fixture no da errores (usar `min_stops=3` como parámetro para la fixture; en producción es 20).
  - `test_validate_missing_line`: si se quitan los viajes C2, hay un error que contiene `"C2"`.
  - `test_validate_not_covering_tomorrow`: un feed sin viajes con fecha de mañana da un error.
  - `test_validate_too_few_stops`: con `min_stops=20` y la fixture, da un error.
  - `test_cli_does_not_write_on_invalid`: el CLI con una fixture inválida sale con código 1 y no existe `out/feed.json`.
- [ ] **Step 2: Ejecutar** `cd pipeline && python3 -m unittest -v`. Deben FALLAR.
- [ ] **Step 3: Implementar** `validate_feed(feed, today, min_stops=20)` y `main()` con `argparse`. La descarga se hace con `urllib.request` y un User-Agent genérico (`proximotren-pipeline`), y se descomprime en un directorio temporal. JSON compacto (`separators=(",", ":")`, `ensure_ascii=False`).
- [ ] **Step 4: Ejecutar** `cd pipeline && python3 -m unittest -v`. Todo debe PASAR.
- [ ] **Step 5: Prueba con datos reales:** `cd pipeline && python3 build_feed.py --out out`. Esperado: código 0, `out/feed.json` de menos de 2 MB, y `python3 -c "import json;f=json.load(open('out/feed.json'));print(len(f['stops']),len(f['trips']))"` muestra ≥ 20 paradas y > 500 viajes. Si pesa más de 2 MB, cambiar el formato antes de seguir (por ejemplo, agrupar viajes con las mismas horas). Si se cambia, actualizar el esquema en Task 1 y en Task 3.
- [ ] **Step 6:** Validar con `consenso` y hacer commit: `feat(pipeline): validation and CLI`.

### Task 3: GitHub Action, repo público y Pages

**Files:**
- Create: `.github/workflows/feed.yml`

**Interfaces:**
- Consumes: el CLI de Task 2.
- Produces: `https://jfcaba.github.io/tren/feed.json`, actualizado cada día.

- [ ] **Step 1: Escribir `feed.yml`.** Disparadores: `schedule: cron "30 2 * * *"` (UTC, de madrugada en Madrid), `workflow_dispatch` y `push` a `main` que toque `pipeline/**`. Job `build` con `defaults.run.working-directory: pipeline`: checkout → `setup-python` 3.12 → `python -m unittest discover -s tests -v` → `python build_feed.py --out ../site` → `actions/upload-pages-artifact` con `path: site`. Job `deploy` (`needs: build`): `actions/deploy-pages` con los permisos `pages: write` e `id-token: write`. Si `build` falla, no hay deploy y se mantiene el JSON anterior.
- [ ] **Step 2:** Validar con `consenso` y hacer commit: `ci: nightly feed build and Pages deploy`.
- [ ] **Step 3: Confirmar con el usuario** antes de publicar, porque crea un repo público. Después: `gh repo create JFCaBa/tren --public --source . --push` y `gh api -X POST repos/JFCaBa/tren/pages -f build_type=workflow`.
- [ ] **Step 4:** `gh workflow run feed.yml` y `gh run watch`. Esperado: los dos jobs en verde.
- [ ] **Step 5: Verificar** con `curl -s https://jfcaba.github.io/tren/feed.json | python3 -c "import json,sys;f=json.load(sys.stdin);print(f['version'],f['valid_from'],len(f['trips']))"`. Esperado: `1 <ayer> <n>`.

### Task 4: App: proyecto Flutter, modelos del feed y parseo del RT

**Files:**
- Create: `app/` con `flutter create --org com.jfcaba --project-name proximotren --platforms ios,android app`
- Create: `app/lib/config.dart`, `app/lib/data/feed.dart`, `app/lib/data/realtime.dart`
- Test: `app/test/feed_test.dart`, `app/test/realtime_test.dart`, `app/test/fixtures/feed.json`, `app/test/fixtures/trip_updates.json`

**Interfaces:**
- Produces (`config.dart`): `const feedUrl = 'https://jfcaba.github.io/tren/feed.json'`, `const rtUrl = 'https://gtfsrt.renfe.com/trip_updates.json'`, `const valenciaNordId = '65000'`.
- Produces (`feed.dart`):
  - `class Stop { String id, name; double lat, lon; List<String> lines; }`
  - `class Trip { String id, line, dir /* 'in'|'out' */, dest; Set<String> dates /* 'YYYY-MM-DD' */; List<(String stopId, int secs)> times; }`
  - `class Feed { DateTime generatedAt; String validFrom, validTo; List<Stop> stops; List<Trip> trips; factory Feed.fromJson(Map<String, dynamic>); }`
- Produces (`realtime.dart`):
  - `class RtTrip { int? delaySec; bool canceled; }`
  - `class RtSnapshot { DateTime fetchedAt; DateTime feedTimestamp /* header.timestamp */; Map<String, RtTrip> trips; }`
  - `RtSnapshot parseTripUpdates(Map<String, dynamic> json, DateTime fetchedAt)`. `delaySec` sale **solo** de `tripUpdate.delay` (Renfe lo publica en todas las entidades SCHEDULED). Si falta, es `null` y el tren no cuenta como "en vivo". No se usa el `stopTimeUpdate`, porque su retraso solo vale desde esa parada en adelante. Los números pueden llegar como int o como string, y hay que aceptar ambos. `canceled = trip.scheduleRelationship == 'CANCELED'`.
  - `class RealtimeClient { RealtimeClient(http.Client); Future<RtSnapshot> fetch(); }` con timeout de 10 s. Hace un GET condicional con `If-None-Match` (ETag de la respuesta anterior). Si recibe un 304, devuelve el snapshot anterior con un `fetchedAt` nuevo; como su `feedTimestamp` no cambia, acabará marcado como viejo si Renfe deja de actualizar.

- [ ] **Step 1:** `flutter create` (comando de arriba), luego `flutter pub add http path_provider geolocator timezone shared_preferences`. Copiar en `test/fixtures/` un `feed.json` pequeño hecho a mano con el esquema de Task 1 y un `trip_updates.json` (`header.timestamp` fijo) con 4 entidades: una con `delay: 540`, otra con `delay: "-180"` (string), otra sin `delay` a nivel de viaje y otra `CANCELED`.
- [ ] **Step 2: Escribir los tests que fallan:**
  - `feed_test.dart` → `parses stops and trips`: número de paradas y viajes; `trips[0].times.first == ('65000', 67200)`; `dates.contains('2026-11-15')`.
  - `realtime_test.dart` → `trip-level delay` (540), `string numbers parsed` (`"-180"` → −180), `missing trip delay is null`, `canceled trip` (`canceled == true`), `header timestamp parsed`, `304 reuses previous snapshot` (con `MockClient`: la segunda petición lleva `If-None-Match` y el resultado conserva `trips` y `feedTimestamp`).
- [ ] **Step 3: Ejecutar** `cd app && flutter test`. Deben FALLAR.
- [ ] **Step 4: Implementar** `feed.dart` y `realtime.dart`.
- [ ] **Step 5: Ejecutar** `cd app && flutter test`. Deben PASAR.
- [ ] **Step 6:** Validar con `consenso` y hacer commit: `feat(app): feed and realtime models`.

### Task 5: App: cálculo de la pantalla (lógica pura)

**Files:**
- Create: `app/lib/domain/board.dart`, `app/lib/domain/nearest.dart`
- Test: `app/test/board_test.dart`, `app/test/nearest_test.dart`

**Interfaces:**
- Consumes: `Feed`, `Trip`, `Stop`, `RtSnapshot` (Task 4).
- Produces:
  - `class Departure { String tripId, line, dest; DateTime scheduled, estimated; int? delaySec /* null si previsto */; bool live, canceled; int minutes; }`
  - `class Board { List<Departure>? toValencia /* dir=='in' */, fromValencia /* dir=='out' */; bool rtStale; bool feedStale; bool feedCoversToday; }`. Una lista es `null` cuando **ningún** viaje del feed en ese sentido para en `stopId` sin terminar allí (por ejemplo, "→ València Nord" estando en València Nord): esa sección no se muestra. Una lista vacía significa "Sin trenes próximos".
  - `Board computeBoard(Feed feed, String stopId, tz.TZDateTime now, RtSnapshot? rt, {int perDirection = 3})`
  - `(Stop, double meters) nearestStop(List<Stop> stops, double lat, double lon)` (haversine).
- Reglas:
  - Se consideran los días de servicio `ayer`, `hoy` y `mañana` (Madrid). Siguiendo la regla GTFS, `scheduled = TZDateTime(Madrid, y, m, d, 12).subtract(Duration(hours: 12)).add(Duration(seconds: secs))` ("mediodía menos 12 h"), así los días de cambio de hora salen bien.
  - Se excluyen los viajes cuya **última** parada es `stopId`.
  - El RT es fresco si `rt != null`, `now − rt.fetchedAt < 2 min` y `now − rt.feedTimestamp < 2 min`. `live` es true si el RT es fresco, el viaje está en `rt.trips` con `delaySec != null` y el `trip_id` tiene una sola instancia en la ventana. Si un `trip_id` tiene varias fechas, el RT no se aplica. En vivo, `estimated = scheduled + delay`. Si no, `estimated = scheduled` y `delaySec = null`. `canceled` se aplica si el RT es fresco y la instancia es única.
  - Se incluye el tren si `estimated >= now − 60 s`. `minutes = max(0, (estimated − now).inSeconds ~/ 60)`. Se ordena por `estimated` y se toman `perDirection` por sentido. Los cancelados se incluyen (con `canceled = true`) y cuentan para el límite.
  - `rtStale` es true si el RT no es fresco. `feedStale` es true si `now − generatedAt > 3 días`. `feedCoversToday` indica si `validFrom <= hoy <= validTo`.

- [ ] **Step 1: Escribir los tests que fallan** en `board_test.dart`, con `tz.initializeTimeZones()` y un feed hecho a mano en el propio test:
  - `orders and limits to 3 per direction`
  - `splits by direction`: `in` → `toValencia`, `out` → `fromValencia`
  - `test_excludes_trips_terminating_at_stop`: un viaje `in` que acaba en `65000` no aparece con `stopId='65000'`
  - `test_includes_previous_service_day_after_midnight`: viaje de ayer a `88200` s, `now` = hoy 00:20 → aparece con `minutes == 10`
  - `applies positive delay and marks live`: `delay 540` → `estimated` +9 min, `live`
  - `test_negative_delay`: `delay −180` → `estimated` −3 min y `delaySec == -180`
  - `stale realtime falls back to scheduled`: `fetchedAt` hace 3 min → `live == false`, `rtStale == true`
  - `stale feed timestamp is not live`: `fetchedAt` es ahora pero `feedTimestamp` es de hace 5 min → `rtStale == true`
  - `trip without delay is not live`
  - `ambiguous trip id ignores realtime`: un viaje con 2 fechas en la ventana → `live == false`
  - `late night shows tomorrow first trains`: `now` = hoy 23:50, sin más viajes hoy → sale el viaje de mañana a las 05:30
  - `dst spring forward`: el 2027-03-28 (Madrid), `secs = 36000` → `scheduled` a las 10:00 hora local
  - `dst fall back`: el 2026-10-25, `secs = 36000` → 10:00 hora local
  - `terminal hides direction`: con `stopId='65000'`, `toValencia == null` y `fromValencia` no vacía
  - `canceled trip shown as canceled`
  - `train within last minute still shown`: `estimated = now − 30 s` → aparece con `minutes == 0`; con `now − 90 s` no aparece
  - `feed staleness flags`: `generatedAt` hace 4 días → `feedStale`; `validTo` ayer → `!feedCoversToday`
  - `nearest_test.dart` → `picks closest stop`: con coordenadas al lado de Silla devuelve Silla, con `meters < 500`
- [ ] **Step 2: Ejecutar** `cd app && flutter test test/board_test.dart test/nearest_test.dart`. Deben FALLAR.
- [ ] **Step 3: Implementar** `board.dart` y `nearest.dart`.
- [ ] **Step 4: Ejecutar** `cd app && flutter test`. Todo debe PASAR.
- [ ] **Step 5:** Validar con `consenso` y hacer commit: `feat(app): departure board computation`.

### Task 6: App: repositorio del feed con caché

**Files:**
- Create: `app/lib/data/feed_repository.dart`
- Test: `app/test/feed_repository_test.dart`

**Interfaces:**
- Consumes: `Feed.fromJson`, `feedUrl`.
- Produces:
  - `class FeedRepository { FeedRepository(http.Client client, Directory cacheDir); Future<Feed?> loadCached(); Future<Feed> refreshIfNeeded(tz.TZDateTime now, {Feed? cached}); }`
  - Caché: `cacheDir/feed.json` más `cacheDir/feed_meta.json` (`{"downloaded_at": ISO}`).
  - `refreshIfNeeded` hace siempre un GET condicional (`If-None-Match` con el ETag guardado en `feed_meta.json`), con timeout total de 15 s cuerpo incluido. Si recibe 304, se queda con la caché. Este cambio respecto al spec ("refrescar si no es de hoy o tiene > 12 h") lo propuso la revisión por consenso: detecta el feed nuevo nada más publicarse y cuesta casi nada. Si la descarga falla o vence el timeout y hay caché, devuelve la caché. Si no hay caché, lanza `FeedUnavailable`.
  - Un JSON corrupto se trata como "no hay caché".

- [ ] **Step 1: Escribir los tests que fallan** con `MockClient` (`package:http/testing.dart`) y un directorio temporal:
  - `downloads when no cache`
  - `sends etag and keeps cache on 304`
  - `replaces cache on 200 with new etag`
  - `timeout without cache throws FeedUnavailable`: una petición que nunca completa → `FeedUnavailable` en ≤ 15 s (simulado con `fakeAsync`)
  - `falls back to cache on network error`
  - `test_first_launch_offline_reports_error`: sin caché y con error de red → lanza `FeedUnavailable`
  - `corrupt cache treated as missing`
- [ ] **Step 2: Ejecutar** `cd app && flutter test test/feed_repository_test.dart`. Deben FALLAR.
- [ ] **Step 3: Implementar.** La escritura es atómica: se escribe un `.tmp` y se renombra.
- [ ] **Step 4: Ejecutar** `cd app && flutter test`. Todo debe PASAR.
- [ ] **Step 5:** Validar con `consenso` y hacer commit: `feat(app): cached feed repository`.

### Task 7: App: controlador, ubicación y pantalla

**Files:**
- Create: `app/lib/app_controller.dart`, `app/lib/location.dart`, `app/lib/ui/home_screen.dart`, `app/lib/ui/departure_row.dart`, `app/lib/ui/station_picker.dart`
- Modify: `app/lib/main.dart`, `app/ios/Runner/Info.plist`, `app/android/app/src/main/AndroidManifest.xml`
- Test: `app/test/app_controller_test.dart`, `app/test/home_screen_test.dart`

**Interfaces:**
- Consumes: `FeedRepository`, `RealtimeClient`, `computeBoard`, `nearestStop`.
- Produces:
  - `abstract class LocationSource { Future<(double lat, double lon)?> current(); }`. Devuelve `null` si no hay permiso o el servicio está apagado. Implementación `GeolocatorLocationSource`: pide permiso "mientras se usa", precisión media y timeout de 8 s.
  - `class AppController extends ChangeNotifier` con el constructor `(FeedRepository, RealtimeClient, LocationSource, SharedPreferences, {tz.TZDateTime Function() clock})` y el estado `Feed? feed; Stop? station; double? distanceMeters; bool manualStation; Board? board; String? error; bool needsStationPick`.
  - Métodos: `Future<void> start()`, `onResume()`, `onPause()`, `selectStation(String stopId)`, `retry()`.
  - Comportamiento: `start` carga la caché y, si existe `last_station`, la usa como estación provisional → pinta → en paralelo hace `refreshIfNeeded` (con try/catch: `FeedUnavailable` sin feed → `error`), busca la ubicación y lanza el RT. La ubicación se guarda aunque el feed aún no esté cargado, y la estación se calcula cuando haya feed. Cada operación asíncrona lleva un número de generación: un resultado de ubicación se descarta si mientras tanto el usuario eligió estación a mano o si el controlador se pausó o se destruyó. Nunca hay más de un `Timer`: `onResume` y `retry` cancelan el anterior antes de crear otro, y `dispose` lo cancela. `Timer.periodic(30 s)` refresca el RT y recalcula el board; se para en `onPause`. `onResume` vuelve a calcular la estación por GPS solo si `!manualStation`. Al elegir estación a mano se guarda en `SharedPreferences` (`last_station`) y se pone `manualStation = true` hasta que el proceso muere. Sin ubicación: se usa `last_station` si existe; si no, `needsStationPick = true`. Un error del RT no es un error de pantalla: `board.rtStale` ya lo refleja.
- UI (`home_screen.dart`), como el mockup del spec: arriba el nombre de la estación y la distancia (al tocarlo se abre `station_picker`, que ordena las paradas por distancia si la hay o alfabéticamente si no). Debajo, las secciones "→ València Nord" y "→ Gandia / Moixent". Se oculta la que sea `null` en el `Board`, y una lista vacía muestra "Sin trenes próximos". Cada fila tiene la etiqueta de línea con su color, el destino (`→ Xàtiva`), `N min` (o "ahora" si es 0), la hora estimada HH:mm, el retraso `(+N)`/`(−N)` en minutos si `delaySec != 0`, y el texto "previsto" si `!live`. Las canceladas se muestran como "✕ Cancelado" con la hora tachada. El pie dice "actualizado hace X s · Datos: Renfe". Los avisos van en un banner: "Sin tiempo real" si `rtStale`; "El horario puede estar desactualizado" si `feedStale` o `!feedCoversToday`. Si `error` está puesto y no hay feed, se muestra el mensaje con un botón "Reintentar". El pull-to-refresh llama a `retry()`. Se usa `WidgetsBindingObserver` en `main.dart` para `onResume`/`onPause`, y `ThemeMode.system`.
- `Info.plist`: `NSLocationWhenInUseUsageDescription` = "Para mostrarte la estación de Cercanías más cercana." y `CFBundleDisplayName` = "Próximo Tren". En Android: `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION`, `INTERNET` y `android:label="Próximo Tren"`.

- [ ] **Step 1: Escribir los tests que fallan** (`app_controller_test.dart`, con fakes de `LocationSource`, `MockClient` y `SharedPreferences.setMockInitialValues`):
  - `picks nearest station from location`
  - `test_location_denied_uses_saved_station`: la ubicación da `null` y `last_station='64200'` → estación Silla, `needsStationPick == false`. Sin `last_station` → `needsStationPick == true`
  - `manual station survives resume`: tras `selectStation`, un `onResume` con otra ubicación no cambia la estación
  - `rt failure keeps board with rtStale`
  - `late location does not override manual pick`: una ubicación que llega después de `selectStation` se ignora
  - `single timer after repeated resume`: tras 3 `onResume` seguidos, solo hay 1 petición RT por ciclo de 30 s (`fakeAsync`)
  - `location before feed resolves station when feed arrives`
  - `start uses last_station while location pending`
  - `home_screen_test.dart` → `renders both sections and Datos: Renfe` y `shows retry on first-launch offline`
- [ ] **Step 2: Ejecutar** `cd app && flutter test`. Los tests nuevos deben FALLAR.
- [ ] **Step 3: Implementar** los ficheros de esta tarea.
- [ ] **Step 4: Ejecutar** `cd app && flutter test && flutter analyze`. Todo en verde y sin issues.
- [ ] **Step 5: Probar a mano en el simulador iOS.** `flutter run` en el simulador con la ubicación simulada en Silla (`xcrun simctl location <udid> set 39.3619548,-0.4149813`). Comprobar con `~/Library/Python/3.9/bin/idb screenshot` que sale Silla con las dos secciones y trenes reales. Tocar el nombre de la estación (`idb ui tap`), elegir València Nord y comprobar que no salen los trenes que terminan allí.
- [ ] **Step 6:** Validar con `consenso` y hacer commit: `feat(app): home screen with location and live updates`.

### Task 8: Distribución: APK Android firmado

**Files:**
- Modify: `app/android/app/build.gradle(.kts)` (signingConfig `release` leído de `android/key.properties`)
- Create (fuera del repo, ignorados): `~/keys/proximotren-upload.jks`, `app/android/key.properties`

**Interfaces:**
- Produces: `app/build/app/outputs/flutter-apk/app-release.apk`.

- [ ] **Step 1:** Generar la keystore con `keytool -genkey -v -keystore ~/keys/proximotren-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`. El usuario elige la contraseña en el terminal con `! keytool ...`. Crear `key.properties` con la ruta y el alias.
- [ ] **Step 2:** Configurar el `signingConfig` de release. Comprobar con `git status` que ni `key.properties` ni `.jks` aparecen como cambios a subir.
- [ ] **Step 3:** `cd app && flutter build apk --release`. Esperado: `✓ Built build/app/outputs/flutter-apk/app-release.apk`.
- [ ] **Step 4: Verificar** en un emulador Android: `adb install -r` del APK, simular la ubicación con `adb emu geo fix -0.4149813 39.3619548` y comprobar que la pantalla muestra Silla.
- [ ] **Step 5:** Validar con `consenso` y hacer commit: `build(android): release signing config`. Avisar al usuario de que guarde una copia de seguridad de la keystore.

### Task 9: Distribución: iOS por TestFlight

**Files:**
- Modify: `app/ios/Runner.xcodeproj` (bundle id `com.jfcaba.proximotren`, equipo de firma, firma automática)

**Interfaces:**
- Produces: un build en TestFlight disponible para el usuario.

- [ ] **Step 1:** Revisar el aviso `[!] Xcode` de `flutter doctor -v` y resolverlo (normalmente CocoaPods o el runtime del simulador).
- [ ] **Step 2: El usuario**, en App Store Connect, crea la app "Próximo Tren" con el bundle id `com.jfcaba.proximotren` (se necesita su sesión, así que le daremos instrucciones). En Xcode, el usuario selecciona su equipo en Runner → Signing.
- [ ] **Step 3:** Poner `version: 1.0.0+1` en `pubspec.yaml`. Ejecutar `cd app && flutter build ipa --release`. Esperado: `build/ios/ipa/*.ipa`.
- [ ] **Step 4:** Subir el build con `xcrun altool --upload-app` (con una clave de API de App Store Connect proporcionada por el usuario) o abriendo `build/ios/archive/Runner.xcarchive` en el Organizer de Xcode → Distribute → TestFlight. Responder "No" a la pregunta de cifrado (solo HTTPS estándar) y añadir `ITSAppUsesNonExemptEncryption=false` en `Info.plist`.
- [ ] **Step 5: Verificar** que el build aparece en TestFlight como "Listo para probar" y que el usuario lo instala.
- [ ] **Step 6:** Validar con `consenso` y hacer commit: `build(ios): bundle id and signing`.
