# Tiempo real por estación en nuestro servidor (diseño corto)

Fecha: 24-11-2026 · Parte 2 de 3 del enfoque A. El usuario aprobó el enfoque («si, por estacion»,
«A») y pidió seguir y desplegar tras consenso («adelante, despliega cuando termine consenso»).

## Intención

Hoy cada app descarga cada 30 s el `trip_updates.json` de Renfe entero (~180 KB, toda España) y,
con un tren cerca, `vehicle_positions.json` (~170 KB). Queremos que pida a nuestro servidor solo lo
de su estación (unos cientos de bytes), que el servidor lea Renfe una vez para todos, y tener
la base para las estadísticas por estación de la parte 3. Si nuestro servidor falla, la app sigue
yendo a Renfe directamente, como hoy.

## Enfoques

- **A. `GET /anden/live/<estación>` en la API de Andén, que ya lee Renfe** (`renfe.Feed`, compartido
  con el seguimiento) ← elegido. Necesita saber qué trenes paran en la estación: lo saca de los
  horarios que ya genera el VPS (parte 1, `/opt/anden/data/current`).
- B. Filtrar por núcleo en vez de por estación: respuestas más grandes y no sirve para las
  estadísticas por estación.
- C. Caché de nginx delante de Renfe sin filtrar: ahorra a Renfe pero no al móvil.

## Diseño

- **Horarios en la API:** el contenedor monta `/opt/anden/data` (solo lectura, misma ruta, porque
  `current` es un enlace absoluto). Construye en memoria `estación → trenes que paran` desde
  `index.json` + `feeds/*.json`; recarga cuando `current` apunta a otra generación (comprobado como
  mucho cada 60 s). Si una recarga falla se queda la anterior.
- **Respuesta** (JSON, `no-store`):
  ```
  {"tripsAt": <ts del feed>, "trips": {"<tripId>": {"delay": <s|null>, "cancelled": <bool>}},
   "positionsAt": <ts|null>, "platforms": {"<tripId>": {"platform": "6", "at": <ts>}}}
  ```
  `trips`: los de Renfe que paran en la estación. `platforms`: trenes llegando o parados en
  *esta* estación con vía. Estación desconocida → 404. Trip updates de Renfe no disponibles o de
  hace más de 5 min, u horarios aún no cargados → 503 (la app va a Renfe).
- **nginx:** `location ~ ^/anden/live/<id>$`, solo GET, límite por IP, sin log (la parte 3 añadirá
  el recuento por estación).
- **App:** en cada ciclo de 30 s pide `/anden/live/<estación>`; con la respuesta construye los mismos
  `RtSnapshot` y `PlatformSnapshot` que hoy, así que el tablero no cambia. Si falla (red, ≠ 200,
  JSON raro), hace exactamente lo de hoy contra Renfe. Las vías llegan siempre (ya no hay que
  esperar a que un tren esté a 5 min para bajar 170 KB).
- **Privacidad:** la página dice que el tiempo real de la estación viene de nuestro servidor (que
  ve qué estación consultas, sin registrarlo) y, si no responde, de Renfe.

## No objetivos

- Avisos de Renfe (`alerts.json`, cada 5 min): siguen directos a Renfe.
- Estadísticas (parte 3). Caché en nginx: no hace falta (Python ya reutiliza la lectura de Renfe
  durante 20 s).

## Decidido por Claude (corregible)

- 503 en vez de datos viejos cuando Renfe falla en el servidor, para que la app pruebe Renfe directo.
- Límite nginx 30 peticiones/min por IP con ráfaga de 20 (una app hace 2/min; margen para varias
  personas tras la misma IP).
