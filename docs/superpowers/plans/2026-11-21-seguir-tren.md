# Seguir un tren en vivo (Andén 1.3) — plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Seguir un tren en Andén (avisos de vía, retraso y cancelación) y verlo en vivo en la app, en la Live Activity de iOS y en la notificación de Android.

**Architecture:** Port de What Platform 1.4 (repo `/Volumes/HIKSEMI/Projects/platform`, commits 4a3f80b y 022a24e). Servidor Python en `tren/server/` que lee `trip_updates` y `vehicle_positions` de Renfe y manda APNs (avisos + Live Activity) a iOS. Android: FollowLoop en un servicio en primer plano leyendo Renfe directamente. La app calcula la posición con sus propias paradas del tren (`Trip.times`).

**Tech Stack:** Python 3.12 + httpx[http2] + PyJWT (server), Flutter/Dart (app), flutter_foreground_task + flutter_local_notifications (Android), Swift/ActivityKit + Ruby xcodeproj (iOS).

**Spec:** `docs/superpowers/specs/2026-11-21-seguir-tren-design.md`

## Global Constraints
- Textos en castellano, exactos: «En X · a N paradas», «Hacia X · a N paradas» («a 1 parada»), «Llegando», «En la estación»; avisos «Vía 3», «Cambio de vía: 3 → 5», «Retraso de 7 min», «Va a su hora», «Cancelado»; estado «A su hora», «Retraso N min», «Cancelado»; «Tu tren», «Siguiendo», «Seguir este tren», «Dejar de seguir».
- Content state JSON: `departs` (int epoch s | null), `status`, `platform` (str | null), `usual` (bool: la vía es la habitual), `where` (str | null), `cancelled` (bool).
- Tokens solo en memoria en el servidor y nunca en logs. Activity tokens hasta 512 hex.
- App usa `package:material_ui/material_ui.dart`. iOS app 15.0; Live Activity con `@available(iOS 16.1, *)`.
- Bundle `com.jfcaba.proximotren`, equipo JH8NFJ6XW7, topic Live Activity `com.jfcaba.proximotren.push-type.liveactivity`.
- Servidor en `https://api.whatplatform.uk/anden/` (nginx → contenedor puerto 8520). User-Agent de la app `Anden/1.3`.
- Tests verdes (`flutter test`, `pytest`) y revisión antes de cada commit.

## Review Focus
- Tren sin posición en Renfe (no circula aún, o Renfe no lo publica): sin línea «dónde está», todo lo demás funciona — test en Task 2 y 3.
- Retraso que oscila ±1 min entre lecturas: no avisar por cambios < 2 min — test en Task 3 (Dart) y Task 1 (Python).
- Trip id repetido otro día: el seguimiento es por tripId + salida programada; una posición de otro día no se aplica (solo se acepta la posición si la parada está en la lista y la salida programada está a menos de 3 h) — test en Task 2.
- Token de la Live Activity que llega tarde o tras dejar de seguir: igual que What Platform (generación) — test en Task 5.
- Servicio de Android en su propio isolate: inicializar zonas horarias — revisado en Task 4.

---

### Task 1: Servidor (`tren/server/`)
**Files:** Create `server/anden_api/{__init__,apns,renfe,live,follow,server}.py`, `server/tests/…`, `server/{Dockerfile,compose.yaml,requirements.txt,README.md}`; Modify `platform/deploy/nginx/whatplatform.uk.conf` (location `/anden/`).
**Interfaces:**
- `renfe.py`: `parse_trips(json) -> dict[tripId, (delay_s|None, cancelled)]`, `parse_positions(json) -> dict[tripId, (stopId, status, platform|None)]`; `RenfeClient.fetch()` con ETag, 10 s.
- `live.py`: `where_text(stops: list[(id,name)], stop_id: str, pos) -> str|None`; `status_text(delay, cancelled)`; `content_state(follow, delay, cancelled, pos, now) -> dict`; `changes(before, after) -> list[str]`.
- `follow.py`: `FollowStore` y `Poller` como What Platform pero un tick = 1 lectura de cada feed para todos; fin a salida estimada + 120 s, cancelado + 120 s, 3 h, DELETE.
- `server.py`: `POST/DELETE /follow`, `/health`; valida `tripId` `[0-9A-Za-z_-]{3,40}`, `stopId` `[0-9]{3,8}`, `title` ≤ 80, `stops` 1–120 pares, `scheduled` dentro de [now-3h, now+6h]. Responde 410 si el tren ya salió.
- [ ] Tests (pytest) de parseo, textos, cambios (umbral 2 min), poller (avisos, Live Activity, end una vez), validación HTTP.
- [ ] Commit `feat(server): follow trains on iPhone`.

### Task 2: App — posiciones y «dónde está»
**Files:** Modify `lib/data/positions.dart` (guardar `status` y `stopId` de todos los trenes: `PlatformSnapshot.byTrip` pasa a `Map<String, TrainSighting>` con `platform` opcional); Create `lib/domain/position.dart` (`String? whereText(List<String> stopIds, Map<String,String> names, String stopId, TrainSighting?)`, `Map<String,Object?> contentState(...)`); tests.
- [ ] Tests: los 4 textos, «a 1 parada», tren pasado → null, parada fuera de la lista → null; la vía sigue igual que hoy (tests existentes verdes).
- [ ] Commit.

### Task 3: App — núcleo de seguimiento
**Files:** Create `lib/follow/{follower,follow_logic,follow_loop}.dart`; tests.
**Interfaces:** `FollowedTrain {tripId, stopId, scheduled (DateTime utc), title, usualPlatform?, stops: List<(String id, String name)>}` con `toJson/fromJson/matches(Departure)`; `List<String> changes(Reading before, Reading after)` (`Reading {delaySec?, cancelled, platform?}`); `FollowLoop` (fetch trips + positions, alert, ongoing(title, text), fin) como What Platform.
- [ ] Tests de cambios y del bucle; commit.

### Task 4: Android — servicio
**Files:** pubspec (flutter_foreground_task ^11.0.3, flutter_local_notifications ^23.0.2), AndroidManifest (permisos y `<service>` como What Platform), `lib/follow/follow_service.dart`, icono de notificación.
- [ ] `flutter build apk --debug` OK; commit.

### Task 5: iOS — push y Live Activity
**Files:** `lib/follow/{push_token,push_follower,live_activity}.dart`, `ios/Runner/{AppDelegate.swift,Runner.entitlements,Info.plist,TrainActivityAttributes.swift}`, `ios/FollowActivity/*`, `tools/ios/add_follow_activity_target.rb`; tests de PushFollower con fakes (igual que What Platform).
- [ ] `flutter build ios --simulator --debug` OK y la extensión embebida; commit.

### Task 6: UI
**Files:** `lib/follow/follow_tracker.dart`, `lib/ui/{your_train.dart,departure_row.dart,home_screen.dart}`, `lib/main.dart`, `lib/app_controller.dart` (posiciones cada 60 s mientras se sigue un tren); tests de widgets.
- [ ] Mantener pulsado sigue/deja; campana; panel con «Seguir este tren»; tarjeta grande = tren seguido con «dónde está»; franja «Tu tren» en otra estación; commit.

### Task 7: Publicar
- [ ] Desplegar servidor y nginx en el VPS; `.env` con APNS_* (los mismos valores que What Platform).
- [ ] App ID: capacidad Push en `com.jfcaba.proximotren`; versión 1.3.0+15; web/privacidad; textos de tienda; build a TestFlight; AAB. En Play: declaración de servicio en primer plano (dataSync) con vídeo.
