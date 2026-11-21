# Seguir un tren y verlo en vivo (Andén 1.3) — diseño

## Por qué
Petición del usuario (21-11-2026): en Andén no hay forma de suscribirse a un tren, y quiere ver en la
pantalla principal, mientras espera, el tren en tiempo real «como cuando esperas un Uber». Lo mismo
que ya hace What Platform 1.4 (repo platform, `docs/superpowers/specs/2026-11-21-live-train-design.md`),
que sirve de referencia y de código a portar.

## Decidido con el usuario
- Seguimiento en iPhone con un servidor en el VPS que manda push (avisos + Live Activity), como What
  Platform. Android: servicio en primer plano en el propio móvil, sin servidor.
- Dirección del servidor: `https://api.whatplatform.uk/anden/` (mismo nginx, contenedor aparte).
- Mostrar: cuenta atrás, vía y por dónde va el tren, en la app, en la pantalla de bloqueo / Dynamic
  Island (iOS 16.1+) y en la notificación fija de Android.

## Lo que ve el usuario (decisiones de Claude)
- **Seguir:** mantener pulsado un tren (fila o tarjeta grande) o «Seguir este tren» en el panel de
  paradas. Snackbar «Siguiendo 08:12 a Guadalajara» con «Deshacer». Campana en el tren seguido. Uno
  solo a la vez.
- **Avisos** (notificación normal) cuando, respecto a la lectura anterior: aparece la vía («Vía 3») o
  cambia («Cambio de vía: 3 → 5»); el retraso cambia en 2 min o más («Retraso de 7 min», «Va a su
  hora»); se cancela («Cancelado»). Nada en la primera lectura.
- **Dónde está** (texto, mismo en app, servidor y notificación):
  - parado en una estación anterior: «En Getafe Centro · a 3 paradas»
  - en camino a una estación anterior: «Hacia Getafe Centro · a 3 paradas»
  - llegando a la tuya: «Llegando»; parado en la tuya: «En la estación»
  - sin dato de Renfe para ese tren o ya pasado: nada.
  «a N paradas» = paradas desde esa estación hasta la tuya (1 → «a 1 parada»).
- **Pantalla principal:** en la estación del tren seguido, la tarjeta grande es ese tren (aunque no
  sea el primero) con la línea «dónde está» y «Siguiendo». En otra estación, una franja «Tu tren»
  arriba (hora y destino, vía, cuenta atrás, dónde está); al tocarla abre su estación.
- **Live Activity (iOS 16.1+):** título «08:12 a Guadalajara», cuenta atrás dibujada por iOS, estado
  («A su hora», «Retraso 5 min», «Cancelado»), vía (en vivo o habitual, con «habitual»), dónde está.
- **Android:** notificación fija «08:12 a Guadalajara · Vía 3» / «12 min · Retraso 5 min · En Getafe
  Centro · a 3 paradas».
- El seguimiento termina 2 min después de la salida estimada, 2 min después de una cancelación, a
  las 3 h, o al dejar de seguir.

## Datos (decidido tras mirar Renfe, 21-11-2026)
- Retraso y cancelación: `trip_updates.json` (ya lo usa la app) por `tripId`.
- Vía en vivo y posición: `vehicle_positions.json`, entidad por `tripId` con `stopId` y
  `currentStatus` (STOPPED_AT, INCOMING_AT, IN_TRANSIT_TO); la vía va en la etiqueta y solo cuando
  INCOMING_AT/STOPPED_AT en esa parada.
- Las paradas del tren salen del horario de la app (`Trip.times`): la app envía al servidor la
  lista de paradas desde el origen hasta la tuya (id y nombre). El servidor no necesita el GTFS.
- La hora prevista: la app envía la salida programada (epoch s); el servidor suma el retraso.

## Servidor (`tren/server/`, Python, contenedor en el VPS)
Port del de What Platform (`platform/api/platform_api/{apns,follow,live,server}.py`) adaptado:
- `POST /follow` `{token, env, activityToken?, tripId, stopId, title, scheduled, usualPlatform?,
  stops: [[id, nombre], …], startedAt}`; `DELETE /follow {token}`; `/health`. nginx publica
  `/anden/` → este contenedor (puerto 8520).
- Un solo poller cada 30 s: una lectura de `trip_updates` y una de `vehicle_positions` para todos
  los seguimientos (con ETag), calcula estado, manda avisos y actualizaciones de la Live Activity
  (topic `com.jfcaba.proximotren.push-type.liveactivity`), y un `end` al terminar.
- Misma privacidad: tokens solo en memoria, nada en logs; límites 500 seguimientos.
- Clave APNs: la del equipo (la misma que What Platform); `.env` en `/opt/anden/.env` en el VPS.

## App
- `lib/follow/`: Follower, FollowedTrain (tripId + fecha de servicio + stopId), lógica de cambios,
  FollowLoop (Android), FollowService (flutter_foreground_task + flutter_local_notifications),
  PushFollower + PushToken (iOS), LiveActivity, FollowTracker — portados de What Platform.
- `lib/domain/position.dart`: posición y textos en castellano a partir de las posiciones de Renfe y
  las paradas del tren; `contentState()` gemelo del servidor.
- `lib/data/positions.dart`: guardar también estado y parada de cada tren (hoy solo la vía).
- Mientras se sigue un tren, las posiciones se piden cada 60 s aunque no haya trenes cerca.
- iOS: extensión `FollowActivity` (SwiftUI) y canal `anden/activity`, `NSSupportsLiveActivities`,
  capacidad Push en el App ID y `aps-environment`.
- Versión 1.3.0+15. Política de privacidad (web/) y etiqueta de App Privacy de iOS («Device ID ·
  Not Linked · App Functionality»).

## No entra
Varios trenes, seguir desde otra estación, botones en la notificación, mapa, Wear/CarPlay.

## Enfoques considerados
1. **Servidor push en el VPS para iOS + servicio en primer plano en Android (elegido):** funciona con
   la app cerrada en ambos; reutiliza What Platform.
2. Solo en la app (sin avisos fuera): no cumple «avisos» ni la pantalla de bloqueo.
3. Push para ambos (Android vía FCM): añade Firebase; anti-objetivo (sin terceros).
