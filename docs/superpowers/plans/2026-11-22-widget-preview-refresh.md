# Widget: vista previa y refresco solo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Vista previa con ejemplo en la galería y widget que se pone al día solo con el tiempo real de Renfe (iOS y Android).

**Architecture:** La app escribe un snapshot con ~60 trenes y horas programadas; el widget (Swift `NextTrainsProvider`, Kotlin `NextTrainsWidgetProvider` + `Worker`) descarga `trip_updates.json`, guarda los retrasos de los trenes del snapshot y calcula la salida = programada + retraso según la regla de frescura.

**Tech Stack:** Flutter/Dart, SwiftUI/WidgetKit, Kotlin, androidx.work.

**Spec:** `docs/superpowers/specs/2026-11-22-widget-preview-refresh-design.md`

## Global Constraints
- Snapshot: `{station, via, updatedAt (epoch s), trains:[{line, color, dest, sched, arrSched|null, delaySec|null, canceled, platform|null, live, rt|null}]}`, máx. `widgetTrains = 60`, sin trenes ya salidos.
- Frescura, evaluada en cada entrada / cada `onUpdate` con su hora: manda la fuente más reciente que tenga < 30 min — tiempo real del widget (`fetchedAt` > `updatedAt`, y `header.timestamp` < 30 min) o la app (`updatedAt`); si ninguna, programada, sin retraso ni cancelación. Sin red, los retrasos caducan solos y los trenes salidos se van (Android: alarma de salida y `updatePeriodMillis` siguen llamando a `onUpdate`).
- La caché `widget_rt` guarda todo el feed (id → retraso, cancelado), no solo los ids del snapshot: un cambio de estación durante la descarga no deja trenes sin datos. Retraso por tren (`tripUpdate.delay`), como la app.
- Con tiempo real del widget fresco, un tren con `rt` que no aparece en él va a su hora (sin retraso, no cancelado); sin `rt`, siempre a su hora.
- `User-Agent: Anden/1.4`, timeout 10 s; un fallo de red no borra nada.
- iOS: entradas por minuto hasta 120, `.after(now + 15 min)`. Android: `PeriodicWorkRequest` 15 min, red conectada, nombre único `anden_widget_rt`, KEEP; cancelado en `onDisabled`.
- Textos: «Abre Andén para ver los próximos trenes». Vista previa de ejemplo: Atocha, C3 Aranjuez, C4a Parla, C5 Móstoles El Soto, C2 Guadalajara.
- Versión 1.4.0+17.

## Review Focus
- Snapshot antiguo de 1.4 (campo `dep`, sin `sched`): el widget no casca, muestra «Abre Andén…» hasta que la app escriba — Swift con campos opcionales; Kotlin `optLong`.
- Retraso negativo (adelantado) y cancelado en el tiempo real del widget — test de la función de mezcla en Dart (referencia) y la misma tabla en Kotlin.
- Tiempo real del widget más antiguo que el `updatedAt` de la app: manda la app.
- Feed de Renfe parado (`header.timestamp` viejo) con descarga reciente: no se aplica.
- Galería con datos reales pero todos los trenes ya salidos: ejemplo, no vacío.

---

### Task 1: Snapshot con horas programadas y 60 trenes (Dart)
**Files:** Modify `app/lib/domain/board.dart` (`Departure.rtId: String?` = `trip.id` cuando `trip.dates.length == 1`), `app/lib/widget/next_trains_widget.dart`, `app/lib/app_controller.dart` (getter perezoso `widgetBoard` = `computeBoard(... limit: widgetTrains)` con los mismos filtros/via, invalidado en `_recompute`), `app/lib/main.dart`; Test `app/test/widget_snapshot_test.dart`, `app/test/board_test.dart`.
- [ ] Tests: campos nuevos (`sched`, `arrSched` sin retraso, `delaySec`, `rt` solo con id de un día); máx. 60; `widgetBoard` respeta `via`.
- [ ] Implementar; `flutter test` verde.

### Task 2: iOS
**Files:** Modify `app/ios/FollowActivity/NextTrainsWidget.swift`.
- [ ] `WidgetTrain` con campos opcionales; `RtCache {fetchedAt, feedAt, trips: [id: (delay, canceled)]}` en el App Group (`widget_rt`), con todo el feed.
- [ ] `getTimeline`: descarga con `URLSession` (timeout 10 s), guarda caché, `resolve(board, rt, now)` aplica la regla; entradas y `.after(+15 min)`.
- [ ] `placeholder` y `getSnapshot(isPreview)` con `sampleBoard` si no hay trenes futuros reales.
- [ ] Verificación: compila (`flutter build ios --simulator --debug`); render en el Mac de la vista previa; prueba de `resolve` en un script Swift en el Mac con la tabla del Review Focus.

### Task 3: Android
**Files:** Create `NextTrainsRtWorker.kt` (descarga, guarda `widget_rt` en las prefs de home_widget, pide `updateAppWidget`), `res/layout/next_trains_widget_preview.xml`, `res/drawable-nodpi/next_trains_widget_preview.png`; Modify `NextTrainsWidgetProvider.kt` (`resolve` puro + encolar el worker en `onEnabled`/`onUpdate`, cancelar en `onDisabled`), `next_trains_widget_info.xml` (`previewLayout`, `previewImage`), `app/build.gradle.kts` (`androidx.work:work-runtime:2.11.2`).
- [ ] `flutter build apk --debug`; en el emulador: la galería muestra el ejemplo; con la app cerrada, el worker corre (`adb shell cmd jobscheduler run` / logs) y el widget cambia.

### Task 4: Publicar
- [ ] Versión 1.4.0+17; `docs/store/estado.md`; consenso del diff; commit; TestFlight y AAB.

## Consenso del plan (22-11-2026)
Codex y agy; opencode sin hallazgos. Aceptado: precedencia por fuente más reciente, caché con todo el feed, descarga inmediata en Android, caducidad sin red. Rechazado: retraso por parada (Renfe da `tripUpdate.delay` por tren y la app ya lo usa), URL del feed en el snapshot (hay un solo feed), quitar `dates.length == 1` (misma regla que la app).
