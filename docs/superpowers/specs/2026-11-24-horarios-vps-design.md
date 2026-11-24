# Horarios de Andén en el VPS (diseño corto)

Fecha: 24-11-2026 · Aprobado por el usuario en conversación («me parece bien»).

Parte 1 de 3 del enfoque A (horarios → tiempo real por estación → /admin de Andén).

## Intención

Generar y servir los horarios (`index.json`, `feeds/<núcleo>.json`, `feed.json`) desde nuestro
servidor en vez de solo GitHub Pages. Motivos: poder hacer privado el repo `tren` más adelante y
que la parte 2 (tiempo real por estación) tenga los horarios en el mismo servidor.

## Enfoques

- **A. Cron en el VPS con el mismo pipeline + nginx sirve los ficheros** ← elegido (mismo patrón
  que `stations.json` de What Platform, ya en producción).
- B. La API de Andén genera y sirve los horarios: mezcla un proceso nocturno pesado con el
  servidor de seguimiento; sin ventaja.
- C. Seguir en Pages y que el VPS se los descargue: no permite hacer privado el repo.

## Diseño

- **Generación:** `pipeline/vps/feed.sh` en cron de `ubuntu` a las 02:30 UTC, desde el clon del
  recolector (`~/anden-platforms/src`). Ejecuta los tests del pipeline y `build_feed.py` con
  `--platforms ~/anden-platforms/data/platforms.json` (local, sin pasar por GitHub) y
  `--previous-base file:///opt/anden/data/current` (la publicación anterior es la servida).
- **Sustitución segura:** genera en un directorio temporal; si `build_feed.py` falla no se toca
  nada. Si va bien, copia al servido solo los ficheros que cambian (los iguales conservan fecha y
  ETag; así la app recibe 304 y no se baja 3,5 MB de Madrid cada noche) y borra núcleos que ya no
  están. `flock` y log en `/opt/anden/data/feed.log`.
- **Servir:** nginx en `api.whatplatform.uk`: `GET /anden/data/index.json`, `/anden/data/feed.json`,
  `/anden/data/feeds/<…>.json`; solo `.json`, gzip, ETag, `Cache-Control: public, max-age=600`
  (como Pages), sin log (no cuenta en ninguna estadística).
- **App (próxima versión):** los horarios se piden a `https://api.whatplatform.uk/anden/data`; si
  falla (error de red, no-200), se prueba GitHub Pages antes de usar la caché. `privacyUrl` sigue
  en Pages.
- **Sin cambios:** el workflow `feed.yml` y GitHub Pages siguen igual (apps instaladas, páginas de
  privacidad y soporte enlazadas desde las tiendas).

## No objetivos

- Mover privacidad/soporte (`render_pages.py`) al servidor: van cuando se haga privado el repo.
- Tiempo real y /admin (partes 2 y 3).

## Decidido por Claude (corregible)

- Código del cron desde el clon del recolector, actualizado a mano (`git pull`), como `collect.sh`.
- Primera ejecución con `--previous-base` de Pages, para que la comparación con lo anterior
  (encogimiento > 50 %) funcione desde el primer día.
- Reserva a Pages en la app.

**Nota tras el deploy (24-11-2026):** se quitó el enlace duro de ficheros iguales: todos llevan
`generated_at` (la app lo usa para avisar de horarios viejos) y cambian cada noche, así que nunca
eran iguales. Las apps reciben 304 durante el día y una descarga por noche, como con Pages.
