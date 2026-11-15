# Próximo Tren multinúcleo: plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extender la app y el pipeline de Valencia C1/C2 a los 15 núcleos de Cercanías de Renfe, con una pantalla común: una lista de los próximos trenes de la estación más cercana, con filtros por destino.

**Architecture:** `pipeline/build_feed.py` lee el GTFS nacional en una sola pasada y publica en Pages tres cosas: `index.json` (núcleos y estaciones), `feeds/<núcleo>.json` (horario v2 por núcleo) y el `feed.json` v1 de Valencia, que se mantiene por compatibilidad. Si un núcleo no pasa la validación, se vuelve a publicar su fichero anterior. La app cachea el índice y los núcleos visitados, elige la estación más cercana en el índice, carga los núcleos de esa estación y calcula una lista única de salidas, filtrable por destino.

**Tech Stack:** igual que antes: Python 3.9+ solo con la biblioteca estándar (`unittest`), GitHub Actions y Pages, Flutter 3.50 (`http`, `path_provider`, `geolocator`, `timezone`, `shared_preferences`).

**Spec:** `docs/superpowers/specs/2026-11-15-multinucleo-design.md` (amplía `docs/superpowers/specs/2026-11-15-cercanias-valencia-design.md`)

## Global Constraints

- Núcleos = prefijo de 2 cifras de `route_id`: 10 Madrid, 20 Asturias, 30 Sevilla, 31 Cádiz, 32 Málaga, 40 Valencia, 41 Murcia/Alicante, 45 Murcia/Cartagena, 46 Ferrol, 47 León, 51 Rodalies de Catalunya, 60 Bilbao, 61 San Sebastián, 62 Santander, 70 Zaragoza.
- Se incluyen todas las rutas con `route_short_name` distinto de `BUS`. El color de cada línea sale de `route_color` (hex sin `#`).
- Los viajes se conservan enteros en el núcleo de su `route_id`. Una estación pertenece a todos los núcleos cuyos viajes paran en ella.
- La ventana es de 7 días (`today−1 .. today+7`) para todos los núcleos, salvo una regla registrada en la Task 7.
- Validación por núcleo: hay viajes hoy y mañana, ≥ 50 % de las paradas y ≥ 50 % de los viajes de la publicación anterior de ese núcleo. Si falla, o si el núcleo desaparece del GTFS, se vuelve a publicar su fichero anterior. El `feed.json` v1 sigue la misma regla y, si no hay anterior, se omite con un aviso. La Action solo falla si ningún núcleo v2 queda publicado.
- Se sigue publicando `feed.json` v1 (Valencia C1/C2, con el esquema de antes) para los builds 1–4.
- Salen los 8 próximos trenes por estación. Los filtros por destino van con "Todos" por defecto, varios destinos se combinan con O, y la selección se guarda por estación en `SharedPreferences` (`filters_<stopId>`).
- Sin cambios: tiempo real cada 30 s, "en vivo" < 2 min, caché con GET condicional, formato `h:mm`, paradas desplegables con una abierta a la vez, nombre corto "València Nord", el tren que termina en tu estación no sale.
- URLs: `https://jfcaba.github.io/tren/index.json` y `https://jfcaba.github.io/tren/feeds/<id>.json`.
- Antes de cada commit se valida el diff con la skill `consenso` (regla del usuario).

## Review Focus

1. **Estación compartida por dos núcleos** (por ejemplo, Cistierna, 47+60): la lista mezcla los trenes de ambos núcleos. Test: `test_shared_stop_lists_both_nucleos` (Task 1) y `merges departures of several feeds` (Task 5).
2. **Un núcleo falla en la Action nocturna**: los demás se publican y ese mantiene su fichero anterior. Test: `test_failed_nucleo_republishes_previous` (Task 2).
3. **Un filtro guardado con un destino que ya no existe**: se descarta y, si no queda ninguno, se vuelve a "Todos". Test: `stale filter falls back to all` (Task 6).
4. **Cambio de ciudad**: abrir la app en Madrid después de haber estado en Valencia carga el núcleo de Madrid sin mezclar trenes de Valencia. Test: `moving to another nucleo loads its feed` (Task 6).
5. **Primer arranque sin red y sin caché del índice**: mensaje y "Reintentar", nunca pantalla vacía. Test: `first launch offline without index reports error` (Task 6).

---

### Task 1: Pipeline: feeds v2 por núcleo + índice

**Files:**
- Modify: `pipeline/build_feed.py`
- Create: `pipeline/tests/fixtures/multi/{routes,trips,stop_times,stops,calendar}.txt`, `pipeline/tests/test_nucleos.py`

**Interfaces:**
- Produces: `NUCLEO_NAMES: dict[str, str]` (las 15 entradas de Global Constraints).
- Produces: `build_nucleos(gtfs_dir: Path, today: date, days: int = 7) -> dict[str, dict]`, que devuelve un feed v2 por núcleo:
  ```json
  {"version":2,"nucleo":"10","name":"Madrid","generated_at":"…Z","valid_from":"2026-11-14","valid_to":"2026-11-22",
   "lines":{"C4a":"0070C0"},
   "stops":[{"id":"18000","name":"Madrid-Atocha Cercanías","lat":40.4,"lon":-3.69}],
   "trips":[{"id":"…","line":"C4a","dest":"Parla","dates":["2026-11-15"],"times":[["18000",67200]]}]}
  ```
  Una sola pasada sobre `stop_times.txt` para todos los núcleos. Un `route_color` que no sea un hexadecimal de 6 caracteres pasa a `9E9E9E`. (El v1 se sigue generando con `build_feed` en otra pasada, unos 10 s más en CI: se acepta por simplicidad.) Se reutilizan `_rows`, `_secs`, `_service_dates` y las reglas de la v1: se omiten las paradas sin hora, se descartan los viajes con horas ≥ 48:00 y los que tienen paradas desconocidas, y el aviso de varias fechas se resume en una línea.
- Produces: `build_index(feeds: dict[str, dict]) -> dict`:
  `{"version":2,"generated_at":…,"nucleos":[{"id","name","feed":"feeds/<id>.json"}],"stops":[{"id","name","lat","lon","nucleos":["47","60"]}]}`, con cada estación una sola vez.
- `build_feed` (v1 Valencia) no cambia.

- [ ] **Step 1: Crear la fixture `multi`** con dos núcleos (`10`: rutas `10T0001C4a`, color `0070C0`, y `10T0002BUS`; `47`: ruta `47T0001C1`) más la ruta `60T0001C1`. Paradas: `18000` Atocha, `18002` Parla, `05761` Cistierna (servida por 47 y por 60), `05803` León, `99001` Bilbao. Un viaje por ruta con servicio diario `20261101–20261130`, cabeceras y valores con espacios de relleno.
- [ ] **Step 2: Escribir los tests que fallan** (`test_nucleos.py`):
  - `test_one_feed_per_nucleo`: las claves son `{"10","47","60"}`. El viaje BUS no aparece. `feeds["10"]["lines"] == {"C4a":"0070C0"}`.
  - `test_trip_schema_v2`: el viaje de C4a tiene `dest=="Parla"` y no tiene clave `dir`. `version == 2` y `name == "Madrid"`.
  - `test_shared_stop_lists_both_nucleos`: en el índice, `05761` aparece una vez con `nucleos == ["47","60"]`.
  - `test_invalid_route_color_defaults_to_grey`: una ruta con `route_color` vacío → `9E9E9E`.
  - `test_index_lists_nucleos_with_feed_paths`: `{"id":"10","name":"Madrid","feed":"feeds/10.json"}` está en `index["nucleos"]`.
- [ ] **Step 3:** `cd pipeline && python3 -m unittest -v` → FALLA (`build_nucleos` no existe).
- [ ] **Step 4: Implementar** `NUCLEO_NAMES`, `build_nucleos` y `build_index`.
- [ ] **Step 5:** `cd pipeline && python3 -m unittest -v` → todo PASA, incluidos los 16 tests existentes.
- [ ] **Step 6: Medir con datos reales.** `python3 -c` que llama a `build_nucleos` sobre el GTFS descargado, imprime núcleos, viajes y KB por núcleo, y el tiempo total. Esperado: 15 núcleos; Madrid < 4 MB sin comprimir; < 60 s.
- [ ] **Step 7:** `consenso` → commit `feat(pipeline): per-nucleo v2 feeds and station index`.

### Task 2: Pipeline: validación por núcleo con vuelta atrás + CLI + workflow

**Files:**
- Modify: `pipeline/build_feed.py`, `.github/workflows/feed.yml`
- Test: `pipeline/tests/test_nucleos.py`

**Interfaces:**
- Consumes: `build_nucleos`, `build_index`, `build_feed`, `validate_feed` (Task 1 y código actual).
- Produces: `validate_nucleo(feed: dict, today: date, previous: dict | None) -> list[str]`, que da error si no hay viajes hoy o mañana, si `len(stops) < 0.5 * len(previous["stops"])` o si `len(trips) < 0.5 * len(previous["trips"])`.
- CLI: `python3 build_feed.py --out DIR [--zip PATH] [--date D] [--min-stops N] [--previous-base URL]` escribe `DIR/index.json`, `DIR/feeds/<id>.json` y `DIR/feed.json` (v1 Valencia, validado como hoy). `--previous-base` (por defecto `https://jfcaba.github.io/tren`; admite `file://`) sirve para leer `index.json` y `feeds/<id>.json` anteriores. Se recorre la **unión** de los núcleos nuevos y de los del índice anterior: si un núcleo no pasa la validación o falta en el GTFS nuevo, recibe su fichero anterior sin modificar y se imprime `warning: nucleo <id> kept previous: <errores>`. Si no existe fichero anterior, el núcleo se omite del índice. El v1 sigue la misma política: si es inválido, se usa el `feed.json` anterior; si tampoco hay, se omite con un aviso, sin que sea fatal. Si no se puede leer lo anterior (red o 404), se trata como "sin anterior" y se avisa. Código de salida 1 solo si no queda ningún núcleo v2 publicado. Todos los ficheros se escriben de forma atómica.
- El workflow pasa a `python build_feed.py --out ../site` (con el `--previous-base` por defecto). No cambia nada más.

- [ ] **Step 1: Escribir los tests que fallan:**
  - `test_validate_nucleo_ok` y `test_validate_nucleo_too_few_stops_vs_previous`: un previo con el doble de paradas → error.
  - `test_failed_nucleo_republishes_previous`: CLI con la fixture `multi` y `--previous-base file://<tmp>/prev`, donde `prev/feeds/47.json` es un feed v2 con 10 paradas y `"generated_at":"PREV"`. El 47 nuevo tiene 2 paradas, menos del 50 % de 10, así que falla. Resultado: código 0, `out/feeds/47.json` es el previo byte a byte, `out/feeds/10.json` es nuevo e `index.json` incluye el 47.
  - `test_vanished_nucleo_republishes_previous`: el previo tiene `feeds/62.json` y el índice lo lista, pero el GTFS nuevo no trae el 62 → `out/feeds/62.json` es el previo y el índice lo incluye.
  - `test_invalid_v1_without_previous_is_not_fatal`: con la fixture `multi` (sin Valencia) → código 0, sin `feed.json` y con un aviso en stderr.
  - `test_cli_fails_when_no_nucleo_valid`: `--date 2030-01-01` sin previo → código 1 y no se escribe nada en `out`.
  - `test_cli_still_writes_v1_feed`: con la fixture `mini` (Valencia), `out/feed.json` tiene `version==1`.
- [ ] **Step 2:** `cd pipeline && python3 -m unittest -v` → FALLAN.
- [ ] **Step 3: Implementar** `validate_nucleo`, el nuevo `main()` y el workflow.
- [ ] **Step 4:** `cd pipeline && python3 -m unittest -v` → todo PASA.
- [ ] **Step 5: Ejecución real:** `cd pipeline && python3 build_feed.py --out out` → código 0. Comprobar: 15 ficheros en `out/feeds`, `out/index.json` con ≥ 900 estaciones y `out/feed.json` v1. Como el `--previous-base` real aún no tiene `index.json`, se ve el camino "sin anterior".
- [ ] **Step 6:** `consenso` → commit `feat(pipeline): per-nucleo validation with fallback; publish index and feeds`. Push → `gh workflow run feed.yml` → `gh run watch` en verde. Después `curl -s https://jfcaba.github.io/tren/index.json | python3 -c "…len(nucleos)==15"` y `curl -s https://jfcaba.github.io/tren/feed.json | …version==1`.

### Task 3: App: modelos v2 (índice y feed por núcleo)

**Files:**
- Modify: `app/lib/data/feed.dart`, `app/lib/config.dart`
- Create: `app/lib/data/nucleo_index.dart`, `app/test/fixtures/index.json`, `app/test/fixtures/feed_10.json`, `app/test/fixtures/feed_40.json`
- Modify tests: `app/test/feed_test.dart`, `app/test/fixtures/feed.json` (pasa a v2)

**Interfaces:**
- Produces (`feed.dart`):
  - `Trip` pierde `dir`.
  - `Feed` gana `nucleo: String`, `name: String` y `lineColors: Map<String,int>` (ARGB, `0xFF000000 | hex`).
  - `Feed.fromJson` acepta solo `version == 2`.
  - `Stop` no cambia.
- Produces (`nucleo_index.dart`):
  - `class IndexStop { String id, name; double lat, lon; List<String> nucleos; }`
  - `class NucleoInfo { String id, name, feedPath; }`
  - `class NucleoIndex { DateTime generatedAt; List<NucleoInfo> nucleos; List<IndexStop> stops; factory NucleoIndex.fromJson(Map<String,dynamic>); NucleoInfo? nucleo(String id); }`
- `config.dart`: `const baseUrl = 'https://jfcaba.github.io/tren'`. `feedUrl` se elimina. Se mantiene `rtUrl`.

- [ ] **Step 1: Escribir las fixtures v2.** `feed_40` es Valencia, con los datos de la fixture actual y sin `dir`. `feed_10` es Madrid, con 2 líneas, 3 paradas y 3 viajes. `index.json` lleva los dos núcleos y una parada compartida de prueba (`"X1"`, `nucleos:["10","40"]`). Escribir los tests que fallan:
  - `feed_test`: `parses v2 feed with line colors` (`lineColors['C1'] == 0xFF7AB3DE`, `nucleo == '40'`) y `rejects v1 feed`.
  - `nucleo_index_test`: `parses index` (núcleos, estaciones, `nucleos` de la compartida) y `looks up nucleo by id`.
- [ ] **Step 2:** `cd app && flutter test` → FALLAN. Los tests de board, controller y UI que usan `dir` se arreglan en las Tasks 4–6; en esta tarea solo se ejecutan `test/feed_test.dart test/nucleo_index_test.dart`.
- [ ] **Step 3: Implementar.**
- [ ] **Step 4:** `flutter test test/feed_test.dart test/nucleo_index_test.dart` → PASA.
- [ ] **Step 5:** Este commit va junto con la Task 4, para no dejar el árbol sin compilar.

### Task 4: App: caché genérica de JSON (índice y núcleos)

**Files:**
- Modify: `app/lib/data/feed_repository.dart` → renombrar a `app/lib/data/json_cache.dart`
- Modify: `app/test/feed_repository_test.dart` → `app/test/json_cache_test.dart`

**Interfaces:**
- Consumes: `Feed.fromJson`, `NucleoIndex.fromJson`, `baseUrl`.
- Produces: `class JsonCache<T> { JsonCache(http.Client, Directory dir, {required String url, required String name, required T Function(Map<String,dynamic>) parse, Duration timeout = 15 s}); Future<T?> loadCached(); Future<T> refresh(); }`. Es el comportamiento actual de `FeedRepository` (ETag ligado a lo que tiene en memoria, refresh serializado, escritura atómica, no descarta la descarga si falla el disco, `FeedUnavailable`), parametrizado. Ficheros `<name>.json` y `<name>_meta.json`.
- Produces: `JsonCache<NucleoIndex> indexCache(http.Client, Directory)` (url `$baseUrl/index.json`, name `index`) y `JsonCache<Feed> nucleoCache(http.Client, Directory, String id)` (url `$baseUrl/feeds/$id.json`, name `feed_$id`).

- [ ] **Step 1:** Mover los tests actuales del repositorio a `json_cache_test.dart` sobre `nucleoCache(..., '40')` con la fixture `feed_40.json`, y añadir `index cache uses its own files` (índice y feed en el mismo directorio no se pisan).
- [ ] **Step 2:** `flutter test test/json_cache_test.dart` → FALLA.
- [ ] **Step 3: Implementar** (renombrar y generalizar `FeedRepository`).
- [ ] **Step 4:** `flutter test test/json_cache_test.dart test/feed_test.dart test/nucleo_index_test.dart` → PASA.
- [ ] **Step 5:** El commit va junto con la Task 5.

### Task 5: App: lista única con filtros (lógica pura)

**Files:**
- Modify: `app/lib/domain/board.dart`, `app/test/board_test.dart`

**Interfaces:**
- Consumes: `Feed` v2, `RtSnapshot`.
- Produces:
  - `Departure` gana `color: int` (de `feed.lineColors`, gris `0xFF9E9E9E` si falta). El resto no cambia (incluidos `stops` e `id`).
  - `class Board { List<Departure> departures; List<String> missingNucleos /* núcleos de la estación sin feed disponible */; List<String> destinations /* todos los destinos con salida desde esta estación en la ventana, de más a menos frecuente; empate → alfabético */; bool rtStale, feedStale, feedCoversToday; }`
  - `Board computeBoard(List<Feed> feeds, String stopId, tz.TZDateTime now, RtSnapshot? rt, {Set<String> destinations = const {}, int limit = 8, List<String> requiredNucleos = const []})`. `missingNucleos` son los de `requiredNucleos` que no tienen feed. Junta los viajes de todos los feeds. Si `destinations` no está vacío, filtra con `dest ∈ destinations`. `feedStale` y `feedCoversToday` se calculan con el peor de los feeds.
  - Se mantienen todas las reglas actuales: zona de Madrid, ayer/hoy/mañana, mediodía − 12 h, frescura del tiempo real, ambigüedad, cancelados, margen de 60 s, se excluye la última parada.

- [ ] **Step 1: Adaptar `board_test.dart`.** Los `out()`/`inb()` pasan a construir `Trip` sin `dir`, y las aserciones `fromValencia`/`toValencia` pasan a `departures` filtradas por destino. Los tests de DST, medianoche, cambio de mes, retrasos, cancelados, ambigüedad y frescura se mantienen tal cual. Tests nuevos:
  - `orders all departures by estimated time and limits to 8`
  - `filters by destinations (OR)`: `{Gandia}` → solo Gandia; `{Gandia, València Nord}` → los dos.
  - `destinations sorted by frequency`
  - `merges departures of several feeds`: un feed 47 y otro 60 con la misma parada → salidas de ambos.
  - `departure color comes from its feed`
  - `reports missing nucleos`: `requiredNucleos ['47','60']` con solo el feed del 47 → salidas del 47 y `missingNucleos == ['60']`.
  - `terminating trips do not offer their destination`: en `65000`, la lista de `destinations` no incluye "València Nord".
- [ ] **Step 2:** `flutter test test/board_test.dart` → FALLA.
- [ ] **Step 3: Implementar.**
- [ ] **Step 4:** `flutter test test/board_test.dart test/json_cache_test.dart test/feed_test.dart test/nucleo_index_test.dart test/nearest_test.dart test/realtime_test.dart test/format_test.dart test/names_test.dart` → PASA.
- [ ] **Step 5:** `consenso` sobre las Tasks 3–5 → commit `feat(app): v2 models, generic json cache, merged departure list with destination filters`. La suite de la UI y el controlador sigue en rojo hasta la Task 6, y se indica así en el mensaje del commit.

### Task 6: App: controlador multinúcleo + pantalla con filtros

**Files:**
- Modify: `app/lib/app_controller.dart`, `app/lib/main.dart`, `app/lib/ui/home_screen.dart`, `app/lib/ui/departure_row.dart`, `app/lib/ui/station_picker.dart`, `app/lib/domain/nearest.dart`
- Modify tests: `app/test/app_controller_test.dart`, `app/test/home_screen_test.dart`, `app/test/support.dart` (el FakeServer sirve `/index.json` y `/feeds/<id>.json`)

**Interfaces:**
- Consumes: `JsonCache`, `indexCache`, `nucleoCache`, `NucleoIndex`, `computeBoard` (lista), `nearestStop`.
- Produces:
  - `nearestStop` se generaliza a `(T, double) nearest<T>(List<T> items, double lat, double lon, {required double Function(T) latOf, required double Function(T) lonOf})`. `nearestStop` se mantiene como envoltorio.
  - Constructor de `AppController`: `(http.Client client, Directory cacheDir, RealtimeClient, LocationSource, SharedPreferences, {clock, periodic})`. Crea él mismo `indexCache` y los `nucleoCache` según los necesita.
  - Estado: `NucleoIndex? index; List<Feed> feeds /* los de la estación actual */; IndexStop? station; Set<String> filters; …`. Se mantiene el resto (distancia, manual, board, error, coords, rt, rtAttempted…).
  - Métodos nuevos: `toggleFilter(String dest)` y `clearFilters()`. La selección persiste en `filters_<stopId>` (lista JSON).
  - Flujo: caché del índice → estación provisional (`last_station`) → refresco del índice, GPS y tiempo real en paralelo. Al tener estación, se cargan sus núcleos: primero la caché y luego el refresco, con un `JsonCache` por núcleo que se conserva en memoria. Los `feeds` se sustituyen por los de los núcleos de la estación, nunca se acumulan. Siguen igual: generaciones de ubicación, un único timer, pausa/destrucción durante el arranque, permisos solo en start/retry/useLocation.
  - **Generación de estación:** cada cambio de estación (GPS, manual o provisional) incrementa `_stationGen`, y los `feeds` se vacían en ese momento. Cada carga de núcleo comprueba la generación después de cada `await` y descarta el resultado si ha cambiado.
  - **Filtros:** los guardados se aplican nada más cargar la estación, pero solo se **reconcilian** (se descartan los destinos que no existen y, si no queda ninguno, se vuelve a "Todos") cuando han terminado las cargas de red de todos los núcleos de la estación, con éxito o con error, y siempre que no falte ninguno. Mientras tanto, o si falta alguno, se conservan.
  - **Estación compartida con un núcleo caído:** se muestran las salidas disponibles y el banner "Horario incompleto: falta <nombre>" (`board.missingNucleos`), con "Reintentar".
  - **Primer arranque sin ubicación y sin `last_station`:** `needsStationPick` y el botón "Elegir estación", como ahora. El selector agrupa por núcleo.
- UI:
  - `home_screen` sustituye las `_Section` por una fila de `FilterChip` con desplazamiento horizontal ("Todos" + `board.destinations`) y la lista `board.departures` con `DepartureRow`. Se mantiene el acordeón y "Sin trenes próximos" si la lista está vacía.
  - `LineBadge` usa `Departure.color`; se elimina el mapa fijo `lineColors`.
  - `station_picker` agrupa por núcleo (cabeceras con el nombre del núcleo, empezando por el actual), y cada grupo va ordenado por distancia o alfabéticamente.

- [ ] **Step 1: Adaptar y escribir los tests que fallan.** Los tests actuales del controlador se adaptan al nuevo constructor. Tests nuevos:
  - `moving to another nucleo loads its feed`: con ubicación en Madrid tras haber usado Valencia → `feeds.single.nucleo == '10'` y ninguna salida de Valencia.
  - `shared station loads both nucleos`: en `X1` → `feeds.length == 2`.
  - `filters persist per station`: `toggleFilter('Gandia')`; un controlador nuevo en la misma estación tiene `filters == {'Gandia'}`.
  - `stale filter falls back to all`: se guarda `filters_64200=["Atlántida"]` → `filters` vacío una vez cargado el núcleo.
  - `saved filters survive while feeds load`: con la red retenida, `filters == {'Gandia'}` hasta que la carga termina.
  - `late nucleo load for previous station is ignored`: se retiene la carga del 40, se cambia a una estación de Madrid, se libera el 40 → `feeds` solo contiene el 10.
  - `shared station with one nucleo offline shows incomplete banner`.
  - `first launch offline without index reports error`.
  - home_screen: `shows filter chips and 8 departures`, `tapping a chip filters the list`, y se adaptan `renders…`, `tapping a train expands…` y `long destinations…` al nuevo layout.
- [ ] **Step 2:** `cd app && flutter test` → FALLAN los nuevos.
- [ ] **Step 3: Implementar.**
- [ ] **Step 4:** `cd app && flutter test && flutter analyze` → todo en verde.
- [ ] **Step 5: Simulador.** Contra el Pages real (publicado en la Task 2):
  - Ubicación en Silla (`39.3619548,-0.4149813`): lista con trenes de C1 y C2 y filtros con Gandia, Moixent, València Nord…
  - Ubicación en Madrid-Atocha (`40.4065,-3.6896`): cambia a Madrid y salen las líneas de Madrid con sus colores.
  - Tocar un filtro y comprobar que la lista se filtra.
  - Capturas con `idb screenshot`.
- [ ] **Step 6:** `consenso` → commit `feat(app): multi-nucleo controller and filtered departure list`.

### Task 7: Rendimiento de Madrid, build 5, TestFlight y APK

**Files:**
- Modify: `app/pubspec.yaml` (`version: 1.0.0+5`)

- [ ] **Step 1: Medir** con `flutter run --profile` en el simulador (no en debug), con la ubicación en Atocha: el tiempo de `Feed.fromJson` + `computeBoard` del núcleo 10, con un `Stopwatch` y `debugPrint` temporales, sin commit. Si pasa de 300 ms, mover el parseo a `Isolate.run` en `JsonCache`, con su test, y anotar la medida y la decisión en el ledger. Si no pasa, se anota la medida y no se cambia nada. La ventana del pipeline no cambia.
- [ ] **Step 2:** Subir la versión a `1.0.0+5`. `flutter build ipa --release` y subida con `xcodebuild -exportArchive` (ExportOptions de la sesión anterior, `destination=upload`). Esperado: `Upload succeeded`.
- [ ] **Step 3:** `flutter build apk --release` → firmado (`apksigner verify` → `CN=Proximo Tren`) → copiar a `~/Desktop/ProximoTren.apk`.
- [ ] **Step 4:** Commit `chore: build 5` (trivial, sin consenso) y push.
