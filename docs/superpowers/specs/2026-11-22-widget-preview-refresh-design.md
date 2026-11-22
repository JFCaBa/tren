# Widget de Andén: vista previa y refresco solo (diseño corto)

## Por qué
Probado el widget de 1.4 (22-11-2026): en la galería de widgets se ve un rectángulo vacío, y una vez
puesto solo cambia al abrir la app. El usuario quiere que se actualice solo, «como Bolsa o Tiempo».

## Decidido con el usuario
1. **Vista previa** con trenes de ejemplo en la galería (iOS y Android).
2. **Refresco solo**: la app deja muchos más trenes (≈60) y el widget descarga por su cuenta el tiempo
   real de Renfe (`trip_updates.json`, ~130 KB) para poner retrasos y cancelados. iOS decide cuándo
   (pedimos cada 15 min, como Tiempo); Android cada 15 min con WorkManager. La cuenta atrás sigue
   minuto a minuto. Si no se abre Andén en un día, se acaban los trenes y dice «Abre Andén…».

## Decisiones de Claude
- La vía la sigue poniendo la app (en vivo o habitual). El widget no descarga `vehicle_positions.json`:
  Renfe solo da la vía mientras el tren llega, y con refrescos de 15 min casi nunca coincidiría.
- Retraso que se muestra, por tren: el del último tiempo real del widget si tiene menos de 30 min (y
  el feed no está parado); si no, el que dejó la app si lo dejó hace menos de 30 min; si no, la hora
  programada, sin retraso. Igual que en la app, un tren sin entrada en un tiempo real reciente va a su
  hora, y el tiempo real solo se aplica a trenes cuyo id es de un solo día (`trip.dates.length == 1`).
- Snapshot nuevo (no compatible con el de 1.4, que solo estuvo en TestFlight): `{station, via,
  updatedAt, trains:[{line, color, dest, sched, arrSched?, delaySec?, canceled, platform?, live, rt?}]}`
  con `rt` = id del trip si se le puede aplicar tiempo real. El widget calcula salida = `sched` + retraso.
- Vista previa iOS: si hay datos reales con trenes futuros, esos; si no, Atocha de ejemplo. Android:
  `previewLayout` propio con ejemplo y `previewImage` PNG para Android < 12.
- iOS: entradas por minuto hasta 2 h y `policy: .after(+15 min)`.

## Enfoques considerados
- Widget con tiempo real propio (elegido).
- App entera en segundo plano (Dart sin interfaz): en iPhone iOS casi no la deja correr.
- Servidor que calcule el tablero: habría que llevar los horarios al VPS y duplicar la lógica.
