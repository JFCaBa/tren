# Andén 1.1: vía en tiempo real y vía habitual

## Intención

La app se llama Andén y todavía no dice por qué vía sale el tren. En estaciones grandes (Atocha, València Nord, Sants) es lo que la gente busca en el panel. Queremos que cada fila de tren diga la vía:
- con antelación, como **vía habitual** aprendida de días anteriores;
- y confirmada **en vivo** cuando Renfe la publica.

El usuario quiere que la parte habitual empiece a aprender cuanto antes; en un par de semanas debería ser útil.

## Qué sabemos del dato (medido el 16-11-2026)

- **Fuente:** `https://gtfsrt.renfe.com/vehicle_positions.json`, unos 170 KB y 460 trenes.
- **Formato de cada entidad:** `vehicle.trip.tripId`, `vehicle.stopId`, `vehicle.currentStatus` y `vehicle.vehicle.label`.
  - La etiqueta es `"<línea>-<número de tren>"` y, cuando se conoce, termina en `"-PLATF.(<vía>)"`. Ejemplos: `C1-23525-PLATF.(6)` y `C4-23615`.
- **La vía corresponde a la parada `stopId`.** Casi solo aparece con `INCOMING_AT` o `STOPPED_AT`: es la vía de la estación a la que el tren llega o en la que está parado, unos 1–3 minutos antes de salir.
- **Formatos de vía:** casi siempre números (`1`, `12`) y a veces cosas como `2AM`. Se tratan como texto opaco.
- **Cobertura por núcleo:**

  | Núcleo | Trenes con vía |
  |---|---|
  | Madrid | ~80 % |
  | Bilbao | ~80 % |
  | Valencia | ~40 % |
  | Barcelona | ~30 % |

  En muchas estaciones no habrá dato y la fila seguirá sin vía.
- **Cruce con el horario:** los 443 `tripId` muestreados existen en `trips.txt`, y 250 de 251 `stopId` en `stops.txt`. La excepción es `00000`, que se ignora.
- **Número de tren:** el `trip_id` de Renfe sigue el patrón `<servicio:5><número de tren:5><línea>`, por ejemplo `3019L23525C1`.
  - El número de tren se repite cada día para el mismo servicio programado. Es la clave natural para «la vía de este tren».

## Objetivos

1. **Recolector:** cada ~10 minutos guarda las vías observadas sin coste y sin servidor propio.
2. **Build nocturno:** publica la vía habitual por estación y tren dentro de los feeds de cada núcleo.
3. **App:**
   - muestra «Vía N» en vivo cuando Renfe la da para la estación del usuario;
   - si no la hay, muestra «vía N · habitual»;
   - si no hay ninguna de las dos, no muestra nada.

## Fuera de alcance

- Vías en la lista de paradas del tren desplegado.
- Avisos o notificaciones de cambio de vía.
- Filtros por vía.
- Corregir o informar de vías erróneas desde la app.

## Lo que no debe pasar

- Que la app muestre como segura una vía que es solo una suposición: la habitual siempre va marcada como tal.
- Que un fallo del recolector rompa o retrase la publicación nocturna del horario. Sin datos de vía, el horario se publica igual.
- Que la app gaste datos móviles descargando 170 KB cada 30 segundos sin necesidad.
- Ensuciar el historial de `main` con commits automáticos frecuentes.

## Enfoques considerados

1. **GitHub Actions cada 10 min con los recuentos en una rama aparte (`platform-data`) que se sobrescribe.** *Elegido.*
   - Gratis (el repo es público).
   - Sin infraestructura nueva; reutiliza el keepalive.
   - GitHub puede retrasar o saltarse ejecuciones programadas, pero para aprender la vía habitual no importa.
2. **Un commit por pasada en `main`.** Descartado: unos 150 commits al día y el repo crece sin fin.
3. **Cloudflare Workers con almacenamiento y muestreo cada minuto.** Descartado: añade una cuenta y una infraestructura que mantener, y la ganancia no compensa.

Para la app también se valoró mostrar solo la vía en vivo. El usuario prefirió en vivo + habitual.

## Diseño

### 1. Recolector (`pipeline/collect_platforms.py` y workflow `platforms.yml`)

- **Cuándo:** workflow programado `*/10 * * * *` con `concurrency` propio, sin compartir el grupo `pages`. Permiso `contents: write` solo para este workflow.
- **Pasada:**
  1. Descarga `vehicle_positions.json`. Si falla, la pasada termina sin error y sin escribir.
  2. Hace checkout de la rama `platform-data`; si no existe, la crea huérfana.
  3. Lee `platforms.json`.
  4. Por cada vehículo con `PLATF.(x)`, `stopId` distinto de `00000` y estado `INCOMING_AT` o `STOPPED_AT`, añade una observación con:
     - clave `"<stopId>|<número de tren>"`; el número sale del `tripId` (caracteres 6–10) o, si no, de la etiqueta;
     - valor: vía `x`, fecha local de Madrid y `tripId`.
  5. Escribe y hace push con un **único commit sobrescrito** (`--amend` + `--force`) en `platform-data`.
- **Deduplicación:** un mismo tren en la misma estación y el mismo día (fecha local de Madrid; el `tripId` no lleva fecha) cuenta una sola vez.
- **Memoria:** por clave se guardan las **últimas 10 observaciones** (vía + fecha). Se borran las claves sin observaciones en 45 días.
- **Formato de `platforms.json`:** `{"version": 1, "updated": "<ISO>", "obs": {"<stop>|<tren>": [["<vía>", "YYYY-MM-DD"], ...]}}`.
  - Estimación: menos de 1 MB. No hace falta comprimir.
- **Tests (unittest, stdlib):** parseo de la etiqueta (con y sin vía, vías alfanuméricas), deduplicación, límite de 10, poda de 45 días y descarga fallida que no escribe.

### 2. Build nocturno (`build_feed.py`)

- **Entrada:** `--platforms <ruta|URL>`. En CI, el workflow `feed.yml` descarga `platform-data/platforms.json` con `raw.githubusercontent.com` o `git fetch`. Si no está o es inválido, se sigue sin vías y se avisa en el log.
- **Regla de vía habitual,** para una lista de observaciones: la vía más frecuente es habitual si tiene **≥ 2 observaciones** y **≥ 60 %** del total. Si no, no hay vía habitual.
- **Respaldo por línea y destino:** para los trenes sin vía propia en una estación, se aplica la misma regla a todas las observaciones de esa estación con la misma línea y el mismo destino final. La línea y el destino salen del cruce con el horario. Así un tren nuevo o poco observado hereda la vía de sus hermanos.
- **Salida en el feed v2 de cada núcleo:**
  - campo nuevo opcional `platforms`: mapa `stopId → { númeroDeTren → vía }`, con la vía ya resuelta (incluido el respaldo) solo para los trenes de ese feed;
  - **`version` sigue en 2.** La app 1.0 rechaza cualquier feed con otra versión (`app/lib/data/feed.dart:78`) e ignora los campos desconocidos, así que `platforms` se añade sin cambiar la versión;
  - el feed legacy v1 no cambia.
- **Tests:** la regla ≥2/≥60 %, el respaldo, que `platforms` esté ausente o vacío no rompa nada, y que una vía de otra estación no se cuele.

### 3. App (Flutter)

- **Datos:**
  - `Feed` lee `platforms` de forma opcional y `computeBoard` rellena `Departure.usualPlatform`.
  - La clave es el número de tren, que sale del `tripId` con la misma regla que el pipeline.
- **Vía en vivo:** cliente nuevo para `vehicle_positions.json`, igual que `RealtimeClient` (ETag y timeout de 10 s), que devuelve `tripId → (stopId, vía)`.
  - Solo cuenta si el `stopId` del vehículo **es la estación del usuario** (o una de sus `stopId` equivalentes si la estación agrupa varias).
  - `Departure.livePlatform` se rellena con eso.
- **Cuándo se descarga:** solo si el tablero tiene algún tren a **≤ 10 minutos**, con la misma cadencia de 30 s que el tiempo real. Si falla, no se muestra error: el tablero sigue sin vía en vivo.
- **Fila del tren** (`DepartureRow`), debajo del destino:
  - `Vía 3` en negrita cuando hay vía en vivo;
  - si no, `vía 2 · habitual` en gris (el mismo color que «previsto»);
  - si no hay ninguna, nada.
  - Si la vía en vivo y la habitual no coinciden, solo se muestra la en vivo.
- **Accesibilidad:** el texto de la vía entra en la etiqueta semántica de la fila.
- **Tests:** las combinaciones de en vivo/habitual/nada; que una vía en vivo de otra estación no se muestre; que no se descargue sin trenes cercanos; y el formato visible.

### 4. Publicación de la 1.1

- La versión pasa a 1.1.0, con un build nuevo en las dos tiendas y la novedad «Ahora muestra la vía: en vivo cuando Renfe la publica y la habitual de cada tren».
- La ficha de las tiendas se actualiza al final (texto y capturas), cuando haya vías habituales que enseñar.

## Lo que queda al constructor

- Nombres de clases y funciones, y cómo encajar el cliente de posiciones en el `AppController` existente (sin nuevos temporizadores si se puede reutilizar el de 30 s).
- El mecanismo exacto de descarga de `platforms.json` en `feed.yml`.
- Cómo se resuelven las estaciones con varias `stopId` (si existen en el feed actual).

## Decisiones tomadas por mí (revisables)

- Clave por número de tren, con respaldo por línea + destino.
- Umbral ≥ 2 observaciones y ≥ 60 %; memoria de 10 observaciones y poda a 45 días.
- Muestreo cada 10 min.
- Descarga en la app solo con trenes a ≤ 10 min.
- La vía en vivo gana siempre a la habitual.
