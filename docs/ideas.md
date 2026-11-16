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
