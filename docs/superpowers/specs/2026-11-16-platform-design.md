# Platform — Andén para Reino Unido (diseño)

Fecha: 16-11-2026 · Estado: borrador para aprobación
Ubicación provisional: repo `tren`; se moverá al repo `platform` cuando exista.

## Intención

Llevar Andén a Reino Unido: abres la app y ves los próximos trenes de National Rail
en la estación más cercana, con retrasos, cancelaciones y andén, sin buscar nada.
Reino Unido es el país analizado con mejores datos (el andén viene en el feed) y un
mercado grande. Gratis y sin anuncios, como Andén.

**Éxito:** un viajero abre la app en el andén y en ~2 s ve el próximo tren, su hora
real y su andén, igual de fiable que los paneles de la estación.

## Objetivos

- Paridad de producto con Andén 1.1: estación más cercana por GPS, lista de próximas
  salidas, hora prevista vs. real, cancelados, andén, filtro por destino, elegir otra
  estación a mano, recordar la última estación, refresco cada 30 s con la pantalla
  abierta, enlace a la política de privacidad.
- App en inglés (en-GB), iOS y Android.

## No objetivos (v1)

- Widgets, favoritos casa/trabajo, notificaciones, llegadas, planificador de viajes,
  billetes, mapas, Apple Watch. (KISS: lo mismo que Andén.)
- Otros operadores fuera de National Rail (metro de Londres, tranvías, autobuses).
- Compartir código con Andén.

## Antiobjetivos

- Clave de Darwin dentro de la app.
- Cuentas de usuario, anuncios, analítica o cualquier recogida de datos
  (privacidad "Data Not Collected", como Andén).
- Coste extra de servidor: se usa el VPS que ya existe (sin cupos ni pagos nuevos).

## Restricciones

- **Licencia (bloqueante):** no se escribe código hasta que el usuario tenga cuenta en
  el Rail Data Marketplace y hayamos leído juntos el acuerdo de la plataforma y la
  licencia del Live Departure Board. Lo que sabemos: gratis, licencia abierta (OGL con
  enmiendas), atribución a National Rail obligatoria; uso comercial sin confirmar
  (Platform no es comercial: gratis y sin anuncios).
- **Atribución:** texto de atribución a National Rail visible en la app (pie de la
  pantalla de salidas) y en las fichas de las tiendas, con la redacción exacta que
  pida la licencia.
- **Cupos:** el VPS no tiene cupo de peticiones; nginx sirve desde su caché sin tocar
  el servicio. Darwin: según la licencia (por confirmar); la caché de 30 s por CRS
  limita las consultas a Darwin al número de estaciones consultadas, no de usuarios.
- La app solo refresca con la pantalla en primer plano (como Andén). Si el servidor
  responde 429 o 503, espera 5 min antes de reintentar y lo dice en un banner.
- Cuenta de RDM a nombre del usuario como particular. Publicación en tiendas: misma
  titularidad que se decida al publicar (pendiente, ver "Preguntas abiertas").

## Enfoques considerados

1. **Repo nuevo `platform` partiendo de una copia de la app de Andén + servicio
   pequeño en el VPS + lista estática de estaciones.** ← elegido. Reutiliza lo que ya funciona (GPS,
   pantalla, estructura, tests), sin acoplar las dos apps.
2. Una sola app/código compartido para España y Reino Unido: descartado, obliga a
   separar lo común de lo específico y complica las dos.
3. App llamando a Darwin con la clave dentro: descartado, la clave se puede extraer
   y probablemente va contra la licencia.
4. Cloudflare Worker en vez del VPS: descartado por el usuario. El plan gratis cuenta
   también las peticiones servidas desde caché (100.000/día) y el VPS ya existe, no
   tiene cupos y deja sitio para una web de Platform más adelante.
5. Horarios completos en el móvil, como Andén: descartado, Darwin ya da las salidas
   en tiempo real por estación; sería trabajo sin beneficio.

## Diseño

### Piezas

```
[App Flutter] --GET stations.json--> [GitHub Pages]   (estático, se regenera a mano/cron)
      |
      +--GET https://api.whatplatform.uk/departures/{CRS}
              --> [VPS: nginx (TLS, caché 30 s por CRS, sin access log)]
                    --> [contenedor platform-api :puerto local] --x-apikey--> [Darwin LDB (RDM)]
```

### 1. Lista de estaciones (`stations.json`)

- ~2.600 estaciones de National Rail: código CRS (3 letras), nombre, lat/lon.
- Fuente: NaPTAN (registro oficial de paradas del DfT, licencia OGL) — tipo de parada
  de estaciones de ferrocarril, que incluye el CRS. Si falta CRS o coordenadas para
  alguna estación, se cruza con la lista de estaciones del RDM (Knowledgebase).
- Un script Python pequeño la genera y valida (número mínimo de estaciones, CRS
  únicos de 3 letras, coordenadas dentro de Gran Bretaña) y se publica en GitHub
  Pages. Cambia poco: workflow mensual + manual.
- La app la descarga y cachea igual que Andén cachea el índice de núcleos (con
  copia de respaldo si falla la red).

### 2. API (`https://api.whatplatform.uk/departures/{CRS}`)

- Servicio Python pequeño (p. ej. FastAPI o `http.server` + `urllib`, a elección del
  constructor) en un contenedor Docker en `/opt/platform/repo`, escuchando solo en
  `127.0.0.1`, como los demás proyectos del VPS.
- El nombre de la estación sale de `stations.json` en la app (la API solo devuelve
  el `locationName` de Darwin como respaldo).
- Valida el CRS (`^[A-Z]{3}$`); si no, 400.
- Llama al Live Departure Board de Darwin en RDM con la clave leída de un fichero
  `.env` del servidor (fuera del repo, permisos 600); pide las próximas salidas (unas 20, ventana ~120 min) con el detalle
  necesario.
- Devuelve un JSON propio, mínimo y estable (la app no depende del formato de
  Darwin), p. ej.:
  `{"crs":"KGX","name":"London Kings Cross","generatedAt":"...","nrccMessages":[...],
  "services":[{"std":"10:15","etd":"10:22"|"On time"|"Delayed"|"Cancelled",
  "platform":"9"|null,"destination":"Cambridge","operator":"Great Northern",
  "cancelled":false,"delayReason":null}]}`
- Caché 30 s por CRS en nginx (`proxy_cache`, con `proxy_cache_lock` para que mil
  peticiones simultáneas a la misma estación generen una sola consulta a Darwin).
  El servicio también responde `Cache-Control: max-age=30`.
- Errores de Darwin → 502 con cuerpo JSON; la app muestra "no se pudo actualizar" y
  mantiene la última respuesta, como Andén con el tiempo real.
- **Privacidad:** el sitio de nginx va con `access_log off` y el servicio no registra
  IPs; solo se registran errores sin datos del cliente. DNS en Cloudflare en modo
  "DNS only" (sin proxy), así ningún tercero ve el tráfico.
- Atribución en la respuesta para que la app la muestre.

### 3. App

- Copia de `tren/app` en el repo nuevo; nombre "What Platform" o "Platform · Next train" (provisional; dominio whatplatform.uk).
  Bundle id / applicationId provisional `com.jfcaba.platform` (se puede cambiar sin
  coste hasta la primera subida a una tienda).
- URLs de la API y de `stations.json` en `config.dart`, como hoy en Andén.
- **Se queda:** localización y estación más cercana (`location.dart`,
  `domain/nearest.dart`), caché JSON, selector de estación, controlador con refresco
  cada 30 s y recuerdo de la última estación, pantalla principal y fila de salida
  (adaptadas), filtro por destino, enlace de privacidad.
- **Se va:** núcleos, feed GTFS, `board.dart` (cálculo de salidas a partir de
  horarios), tiempo real de Renfe, posiciones y vía habitual.
- **Nuevo:** cliente de la API (`/departures/{CRS}`) con timeout, y modelo
  `Departure` desde la respuesta de la API.
- **Datos viejos:** si falla una actualización se mantiene la última respuesta con
  un banner "Last updated hh:mm"; pasados 10 min sin datos nuevos se dejan de mostrar
  las salidas (pueden ser engañosas) y queda solo el banner con "Retry".
- Pantalla: nombre de la estación + distancia; filas con hora programada, estado
  (On time / Exp 10:22 / Delayed / Cancelled), destino y **andén en grande**
  ("Plat 9"); mensajes de incidencias de la estación (NRCC) en un banner; pie con
  atribución a National Rail y hora de actualización.
- Textos en inglés británico; formato 24 h.

### 4. Infra y publicación

- Dominio `whatplatform.uk` (Cloudflare, del usuario). DNS ya creado, en modo
  "DNS only" hacia el VPS (217.182.195.66): `whatplatform.uk`, `www` y `api`.
- Repo nuevo `platform` (GitHub, mismo usuario): `app/`, `api/` (servicio + Dockerfile
  + compose), `pipeline/` (script de estaciones), `deploy/` (sitio de nginx), workflows
  de CI (tests app + api + script) y de publicación de `stations.json` en Pages.
- Despliegue en el VPS siguiendo el patrón de los demás proyectos: `/opt/platform/repo`
  (clon), `docker compose up -d --build`, sitio de nginx con certificado de
  Let's Encrypt (certbot, webroot) y la cabecera/snippets habituales.
- `whatplatform.uk`: página sencilla con la política de privacidad (inglés) servida
  por nginx desde el VPS: sin datos recogidos; la ubicación se usa solo en el
  dispositivo; el servidor solo recibe el código de estación.
- Tiendas: fichas en inglés, Reino Unido; mismo flujo que Andén (prueba cerrada en
  Play con ≥ 12 probadores durante 14 días si la cuenta es personal).

### 5. Fases y puertas

0. **Licencia y spike (puerta):** cuenta RDM aprobada → leer acuerdo y licencia con el
   usuario → suscribirse al Live Departure Board → una llamada real desde la terminal
   para fijar endpoint y formato. Si la licencia prohíbe redistribuir mediante un
   proxy o el uso en una app publicada, se para aquí y se replantea.
1. Script de estaciones + publicación en Pages.
2. API + tests + despliegue en el VPS (nginx, certificado, caché).
3. App: copia de Andén, cliente nuevo, pantalla, textos.
4. Prueba real, privacidad, fichas, tiendas (con confirmación del usuario antes de
   enviar a revisión, como en Andén).

**Quién hace qué:** el usuario tiene la cuenta de RDM (pedida) y escribe la clave de
Darwin en `/opt/platform/.env` del VPS por su cuenta, para que no pase por el chat. Claude crea el repo `platform` en GitHub (con el visto
bueno del usuario), escribe el código, los tests y los workflows. Este documento se
mueve al repo nuevo al crearlo.

## Pruebas

- Script de estaciones: tests con fixture de NaPTAN (CRS válidos, duplicados,
  coordenadas fuera de GB, mínimo de estaciones).
- API: tests con respuestas de Darwin grabadas (normal, cancelado, retrasado, sin
  andén, error de Darwin, CRS inválido, caché).
- App: los tests de Andén que sobreviven + cliente de la API y fila de salida con
  los estados británicos.
- Prueba real: una estación con andenes muy usados (p. ej. Birmingham New Street)
  comparada con el panel de la estación.

## Lo que queda al constructor

- Endpoint exacto del Live Departure Board en RDM y sus parámetros (tras la
  suscripción), y mapeo de sus campos al JSON propio.
- Detalles de NaPTAN (fichero, filtro de tipo de parada, campo del CRS).
- Estructura interna del servicio, su framework y sus tests; puerto local libre.
- Iconos y colores nuevos.

## Preguntas abiertas

- Estaciones de NaPTAN sin CRS o con varias entradas por CRS: se agrupan por CRS
  (centroide) y se descartan las que no tienen CRS. Decisión del diseño.
- Redacción exacta de la atribución y condiciones de uso (al leer la licencia).
- Titular de la publicación en tiendas (particular o 338 TAC) y nombre final de la app
  en las tiendas.
