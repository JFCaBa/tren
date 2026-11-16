# Andén: ideas para próximas versiones

## Ampliar cobertura (anotado 16-11-2026)

Hoy cubrimos los 15 núcleos de Renfe Cercanías, que son todos los del GTFS oficial
(`fomento_transit.zip`). Opciones para crecer, por orden de interés:

1. **FGC (Barcelona) y Euskotren (País Vasco)** — recomendado empezar aquí: mucho uso
   en ciudades donde ya estamos y se perciben como "cercanías". Publican GTFS; falta
   comprobar el tiempo real. Cada operador es un adaptador aparte en el pipeline
   (formato e identificadores propios). La vía (1.1) solo funciona con Renfe.
2. **Cercanías de ancho métrico (ex-FEVE)**: Asturias, Cantabria, Bilbao, León, Murcia,
   Ferrol. Encaje natural, pero Renfe no publica sus horarios en abierto (en
   data.renfe.com solo están las estaciones, y tampoco vienen en el GTFS de AV/LD/MD).
   Hay que buscar si existe otra fuente.
3. **Otros operadores**: Metrovalencia y TRAM d'Alacant (FGV), SFM (Mallorca, ciudad nueva).
4. **Media Distancia / Regionales de Renfe**: datos abiertos (`Fichero_AV_LD/google_transit.zip`,
   `trip_updates_LD.json`, `vehicle_positions_LD.json`), pero encaja peor con
   "el próximo tren desde la estación más cercana": pocos trenes, billete con plaza.

Primer paso cuando se retome: verificar qué datos (horarios y tiempo real) publica
realmente cada operador.

## Otros países (análisis rápido, 16-11-2026)

### Reino Unido — ⭐ SIGUIENTE PROYECTO (decidido 16-11-2026)
- Datos: Darwin (National Rail) vía Rail Data Marketplace, gratuito con registro.
  Salidas en tiempo real por estación con retrasos, cancelaciones y **andén incluido**.
  Una sola fuente para ~2.500 estaciones.
- Arquitectura distinta: Darwin necesita clave → hace falta un pequeño proxy
  (p. ej. Cloudflare Worker); no se puede meter la clave en la app. A cambio sobra
  casi todo el procesado de horarios (se piden las salidas de la estación cercana).
- Competencia muy fuerte (app de National Rail, Trainline, Realtime Trains...).
  Diferenciarse por sencillez. App en inglés.
- Revisión de los 3 puntos previos (16-11-2026):
  1. **Licencia**: el Live Departure Board del RDM es gratuito, licencia abierta (OGL con
     enmiendas), permite redistribuir y exige **atribución a National Rail**. Uso
     comercial NO confirmado: la página de NR sobre paneles públicos habla de uso no
     comercial (aunque se refiere a la web, no a la API). Andén es gratis y sin
     anuncios, lo que ayuda. Antes de escribir código: registrarse en raildata.org.uk
     (lo hace el usuario), leer el PDF de licencia del producto y, si hay dudas,
     preguntar a Rail Delivery Group.
  2. **Servidor**: Cloudflare Worker. Plan gratis = 100.000 peticiones/día (reinicio a
     medianoche UTC, 1.000/min). Con caché por estación de ~30 s y la app consultando
     solo con la pantalla abierta, da para cientos de usuarios diarios; si se queda
     corto, plan de pago (~5 $/mes) sin límite de peticiones. La clave vive en el Worker.
  3. **Competencia**: además de National Rail, Trainline y Realtime Trains, hay muchas
     apps pequeñas de paneles (Railtime, On Rails, Train Times Live, StationWatch,
     Railboard), varias con widgets. Nicho saturado. Diferenciación posible: cero
     configuración (abrir → estación más cercana sola, sin buscar), andén en grande,
     sencillez y privacidad (sin cuenta, sin anuncios, sin datos). Validar con
     usuarios reales antes de invertir mucho.

### Portugal — técnicamente fácil, poco valor sin tiempo real
- CP publica GTFS oficial (MobilityData mdb-2057): el pipeline actual sirve casi entero.
- Sin tiempo real público: CP lo tiene en su web (2024) pero sin API abierta; los
  clientes no oficiales piden permiso a CP para uso en producción.
- Mercado pequeño: urbanos de Lisboa (Sintra, Cascais, Azambuja, Sado) y Oporto
  (Braga, Guimarães, Aveiro). Fertagus es otro operador con datos propios.
- Solo merece la pena si CP da acceso al tiempo real: escribirles para preguntarlo.
- Pendiente: licencia del GTFS de CP.

Fuentes: https://nre.co.uk/developers/ · https://www.nationalrail.co.uk/developers/darwin-data-feeds/ ·
https://raildata.org.uk/dataProduct/P-0a6089d3-069c-4949-85ca-e7fdd62a7a20/overview ·
https://developers.cloudflare.com/workers/platform/limits/ · https://mobilitydatabase.org/feeds/gtfs/mdb-2057 ·
https://cp.pt/institucional/en/press/press-releases/info-tempo-real
