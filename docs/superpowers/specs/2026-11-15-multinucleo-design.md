# Próximo Tren multinúcleo: diseño

Fecha: 2026-11-15. Amplía `2026-11-15-cercanias-valencia-design.md`.

## Intención

El usuario quiere acabar distribuyendo la app en las tiendas. De momento solo Cercanías, pero en **todas las ciudades**: la app muestra los próximos trenes de la estación más cercana, esté donde esté.

Esta fase deja la app multinúcleo funcionando en TestFlight y en APK. La preparación para las tiendas (nombre, icono, política de privacidad, capturas) es la fase siguiente y no entra aquí.

## Objetivos

- Cubrir los 15 núcleos del GTFS de Renfe: Madrid (10), Asturias (20), Sevilla (30), Cádiz (31), Málaga (32), Valencia (40), Murcia/Alicante (41), Murcia/Cartagena (45), Ferrol (46), León (47), Rodalies Catalunya (51), Bilbao (60), San Sebastián (61), Santander (62) y Zaragoza (70).
- Al abrir, sin configurar nada: estación más cercana de toda España, próximos trenes y tiempo real, igual que ahora.
- Se mantiene lo que ya funciona: retraso en vivo y "previsto", paradas desplegables (un tren abierto a la vez), formato `h:mm`, caché sin conexión, coste cero.

## No-objetivos

- Metro, tranvía, FGC, Euskotren u otros operadores.
- Nombre, icono, fichas y textos legales para las tiendas (fase siguiente).
- Proxy o caché del tiempo real (solo si el número de usuarios lo pide).

## Anti-objetivos

- Que la app pese más o vaya más lenta en Valencia por haber añadido Madrid. Solo se descarga el horario del núcleo en el que estás.
- Que el fallo de un núcleo en la Action nocturna deje sin horario a los demás.

## Enfoques considerados

1. **Un fichero por núcleo + un índice** (elegido). La Action publica `index.json`, con los núcleos y todas sus estaciones (pequeño), y `feeds/<núcleo>.json`. La app baja el índice, elige la estación más cercana y descarga solo el núcleo correspondiente. Madrid ocupa unos 570 KB comprimido.
2. Un único fichero nacional: varios MB que se descargarían en cada móvil. Descartado.
3. Un backend que responda "próximos trenes en la estación X": coste y mantenimiento. Descartado mientras no haga falta.

## Pantalla (decisión de Claude; el usuario dijo "dale" sin elegir)

La pantalla de dos sentidos ("→ València Nord / → Gandia") solo funciona en núcleos radiales. En Madrid o Rodalies una estación puede tener 6 líneas hacia 15 destinos. Diseño común para todos:

```
📍 Nuevos Ministerios     350 m ⌄
[Todos] [Atocha] [Alcobendas] [Parla] [Aeropuerto T4] …   ← filtros por destino
C4a → Parla              3 min   21:14 (+1)
C8a → El Escorial        5 min   21:16
C1  → Príncipe Pío       7 min   21:18  previsto
…  (8 próximos trenes)
```

- **Lista única** con los 8 próximos trenes de la estación, ordenados por hora estimada, con la misma fila de ahora (línea, destino, espera, hora, retraso, previsto o cancelado) y las paradas desplegables.
- **Filtros por destino:** "Todos" y los destinos con trenes desde esta estación, ordenados de más a menos frecuentes. Se pueden elegir varios. La selección se guarda **por estación** en el teléfono, así que en tu estación de siempre basta con marcarlo una vez.
- Los trenes que terminan en tu estación no salen (igual que ahora).
- Color de cada línea: el `route_color` del GTFS.

## Datos

- **Pipeline:** se generaliza `build_feed.py`.
  - Los núcleos salen del prefijo de `route_id`, con una tabla de nombres en el código.
  - Entran todas las rutas con `route_short_name` distinto de `BUS`.
  - El campo `dir` desaparece, porque el sentido ya lo dan los destinos de los filtros. `color` va por línea.
- **Validación por núcleo:** si un núcleo no pasa (sin viajes hoy o mañana, o con menos del 50 % de las paradas de la publicación anterior), se vuelve a publicar su fichero anterior, descargado de Pages, y se avisa en el log. La Action solo falla si no pasa ningún núcleo.
- **Índice:** `{"version":2,"generated_at","nucleos":[{"id","name","feed":"feeds/<id>.json","stops":[{"id","name","lat","lon"}]}]}`.
- **App:**
  - Caché del índice y de cada núcleo visitado, con GET condicional igual que ahora.
  - La estación más cercana se busca en el índice entero.
  - El selector de estación permite cambiar de núcleo.
  - Tiempo real: el mismo feed nacional, cruzado por `trip_id` con el núcleo cargado.
- **Compatibilidad:** `feed.json` (Valencia, v1) se sigue publicando hasta que no quede ningún build antiguo en uso. Los builds 1–4 lo leen.

## Reglas concretas (tras la revisión del diseño; datos medidos el 2026-11-15)

- **Estaciones compartidas:** una estación pertenece a todos los núcleos que tienen trenes que paran en ella. Solo hay 17 estaciones así de 925, todas en la línea de vía estrecha León–Bilbao (núcleos 47 y 60). En el índice cada estación sale una vez con su lista de núcleos (`"nucleos":["47","60"]`). La app descarga todos los núcleos de la estación elegida y junta sus trenes en la misma lista.
- **Viajes que salen de su núcleo:** se conservan enteros, con todas sus paradas, en el núcleo de su `route_id`. No se recortan.
- **`trip_id`:** son únicos en todo el GTFS (0 duplicados) y el tiempo real nacional usa los mismos, así que se cruzan por `trip_id` sin más.
- **Ventana de 7 días** también para Madrid: unos 3,5 MB de JSON sin comprimir. El builder mide el tiempo de carga en el simulador. Si pasa de 300 ms, se reduce la ventana de los núcleos grandes a 3 días y se anota la decisión.
- **Filtros:** "Todos" por defecto. Varios destinos se combinan con O. Los destinos guardados que ya no existen se descartan y, si no queda ninguno, se vuelve a "Todos".
- **Cambio de núcleo:** automático por GPS al abrir o volver a la app, salvo que se haya elegido una estación a mano (misma regla que ahora). El selector de estación agrupa por núcleo y empieza por el actual.

## Para el builder

- Estructura de ficheros del pipeline y de la app, y nombres concretos.
- La lista de nombres de núcleo (por ejemplo, "Rodalies de Catalunya", "Madrid", …).
- Cuántos destinos caben en la fila de filtros (desplazamiento horizontal).
