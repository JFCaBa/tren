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

### Reino Unido — viable, el más interesante como producto
- Datos: Darwin (National Rail) vía Rail Data Marketplace, gratuito con registro.
  Salidas en tiempo real por estación con retrasos, cancelaciones y **andén incluido**.
  Una sola fuente para ~2.500 estaciones.
- Arquitectura distinta: Darwin necesita clave → hace falta un pequeño proxy
  (p. ej. Cloudflare Worker); no se puede meter la clave en la app. A cambio sobra
  casi todo el procesado de horarios (se piden las salidas de la estación cercana).
- Competencia muy fuerte (app de National Rail, Trainline, Realtime Trains...).
  Diferenciarse por sencillez. App en inglés.
- Pendiente: condiciones de uso de Darwin (límites, atribución, uso comercial).

### Portugal — técnicamente fácil, poco valor sin tiempo real
- CP publica GTFS oficial (MobilityData mdb-2057): el pipeline actual sirve casi entero.
- Sin tiempo real público: CP lo tiene en su web (2024) pero sin API abierta; los
  clientes no oficiales piden permiso a CP para uso en producción.
- Mercado pequeño: urbanos de Lisboa (Sintra, Cascais, Azambuja, Sado) y Oporto
  (Braga, Guimarães, Aveiro). Fertagus es otro operador con datos propios.
- Solo merece la pena si CP da acceso al tiempo real: escribirles para preguntarlo.
- Pendiente: licencia del GTFS de CP.

Fuentes: https://nre.co.uk/developers/ · https://mobilitydatabase.org/feeds/gtfs/mdb-2057 ·
https://cp.pt/institucional/en/press/press-releases/info-tempo-real
