# Andén /admin: estadísticas por estación (diseño corto)

Fecha: 24-11-2026 · Parte 3 de 3 del enfoque A. Pedido por el usuario («tambien me gustaria …
un admin como el de whatplatform», «si, por estacion», «haz la parte 3»).

## Intención

Una página protegida, como la de What Platform (`api.whatplatform.uk/admin`), para ver el uso de
Andén día a día y qué estaciones importan, y poder enseñarla. Solo agregados; nunca IP, User-Agent
ni identificadores en disco o en logs.

## Enfoques

- **A. Contar en la API de Andén, en `GET /live/<estación>`** (ya pasa por ella sin caché), con
  nginx pasando la IP solo a esa ruta para el recuento diario de personas ← elegido: menos piezas
  que el syslog UDP de What Platform (allí hacía falta porque nginx cachea `/departures`).
- B. Copiar el syslog UDP de What Platform: otra pieza (puerto, formato) sin ventaja aquí.
- C. Mostrar Andén dentro del /admin de What Platform: mezcla dos proyectos y repos.

## Diseño

- **Qué se cuenta:** cada `GET /live/<estación>` con respuesta 200 o 503 (la app estaba mirando
  esa estación) con User-Agent `Anden/…`; y cada `POST /follow` que crea un seguimiento nuevo
  (iPhone; no las re-sincronizaciones del mismo tren: `upsert` devuelve `"renewed"`).
- **Personas:** `HMAC(clave_del_día, IP + User-Agent)` en un set del día, como What Platform; la
  clave es aleatoria, en memoria, y se tira a medianoche **de Madrid**. Como la app consulta cada
  30 s, el ranking de estaciones es por **personas distintas por estación y día** (un set por
  estación), no por peticiones. También: peticiones por hora, versión de la app (del User-Agent).
- **IP:** nginx manda `X-Real-IP $remote_addr` solo en `/anden/live/`; la API la usa un instante y
  la descarta. El resto de rutas sigue sin IP.
- **Almacenamiento:** SQLite en `/opt/anden/stats` (volumen), volcado cada 60 s, copia diaria (7).
  Tablas: días (personas, peticiones, seguimientos), horas, estaciones (personas, peticiones),
  versiones. Reinicio a mitad de día: personas algo infladas; se acepta (como What Platform).
- **Página `/anden/admin`:** en español, hora de Madrid, mismo estilo que la de What Platform:
  tarjetas (personas hoy, estaciones hoy, trenes seguidos ahora / hoy), personas al día (30 días),
  filtro Hoy · 7 d · 30 d · Todo debajo, estaciones más vistas (nombre y núcleo), horas punta,
  versiones. `auth_basic` con el mismo `htpasswd` de What Platform y una cabecera secreta propia
  (`ANDEN_ADMIN_KEY`, solo en el VPS).
- **Privacidad:** `privacidad.html` explica el recuento anónimo (igual que What Platform) y que
  la IP no se guarda.

## No objetivos

- Contar aperturas de la app o descargas de horarios (no pasan por la API).
- Separar iPhone/Android (mismo User-Agent).
- Datos antes de la próxima versión: la 1.4 no usa `/live`, así que la página empezará casi vacía
  hasta que salga la siguiente.

## Decidido por Claude (corregible)

- Recuento en la API con `X-Real-IP` solo en `/live` (enfoque A).
- Ranking por personas distintas, no por peticiones.
- Mismo usuario y contraseña que el /admin de What Platform.
