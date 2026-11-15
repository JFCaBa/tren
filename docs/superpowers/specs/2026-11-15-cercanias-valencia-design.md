# App "próximo tren" Cercanías Valencia (C1/C2) — Diseño

Fecha: 2026-11-15

## Intención

App personal (para el usuario y su mujer) que al abrirse muestra, sin tocar nada, cuántos
minutos faltan para los próximos trenes de las líneas **C1** y **C2** de Cercanías Valencia
en la estación más cercana (por GPS), en **ambos sentidos**, teniendo en cuenta el retraso
en tiempo real.

## Objetivos

- Abrir → ver la respuesta en < 2 s (con datos cacheados) sin interacción.
- Tiempo restante corregido con el retraso real cuando Renfe lo publica.
- iOS (vía TestFlight) y Android (APK enviado por mensajería). Cuentas de desarrollador ya existen.
- Coste cero de infraestructura.

## No-objetivos

- Publicación en App Store / Google Play (quizá en el futuro; no debe impedirse, pero no se prepara).
- Otras líneas (C3, C5, C6…) u otros núcleos de Cercanías.
- Planificador de viajes, transbordos, notificaciones, widgets, mapas.
- Cuentas de usuario, analítica, backend propio.

## Anti-objetivos (fallo aunque "funcione")

- Mostrar una hora segura cuando el dato es solo teórico: siempre debe distinguirse "en vivo" de "previsto".
- Horario caducado sin avisar: si el horario local tiene más de N días o no cubre hoy, avisarlo.
- Pantalla compleja o que exija configurar algo antes de dar la primera respuesta.

## Fuentes de datos (verificadas el 2026-11-15)

| Dato | URL | Notas |
|---|---|---|
| GTFS estático (todo Cercanías España) | `https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip` | ~15 MB zip, `stop_times.txt` ~270 MB. Calendario por fecha (un `service_id` por día, `start_date == end_date`). Campos con espacios de relleno → hacer `trim`. |
| GTFS-RT trip updates | `https://gtfsrt.renfe.com/trip_updates.json` (también `.pb`) | Sin auth. ~300 entidades en toda España. Cada tripUpdate trae normalmente **un solo** `stopTimeUpdate` y un `delay` (segundos, puede ser negativo). `tripId` coincide con `trip_id` del estático (comprobado). Puede haber `scheduleRelationship: CANCELED`. |
| GTFS-RT alertas | `https://gtfsrt.renfe.com/alerts.json` | Opcional, ver "Para el builder". |

Licencia: datos abiertos de Renfe (data.renfe.com), reutilización con atribución → mostrar "Datos: Renfe" en la app.

Filtro Valencia: `route_id` empieza por `40T` y `route_short_name` ∈ {C1, C2}. Hoy: 10 rutas, ~5.600 viajes,
~59.500 stop_times, ~25 paradas, horas máx. 23:47 (aun así soportar horas ≥ 24:00 por estándar GTFS).

## Enfoques considerados

1. **GitHub Action + GitHub Pages + app que lee RT directo** — *elegido por el usuario.* Coste cero,
   horario siempre fresco, la app sigue funcionando offline con la última copia.
2. Backend propio que combine horario + RT y sirva "próximos trenes por estación" — descartado: coste y
   mantenimiento para una app personal.
3. Horario embebido en la app, regenerado a mano — descartado: el calendario por fecha caduca en semanas y
   obliga a recompilar y redistribuir (TestFlight/APK) cada vez.

## Arquitectura

### 1. Pipeline de datos (repo GitHub, Action nocturna)

- Script (Python, sin dependencias exóticas) que: descarga el zip, filtra C1/C2 de Valencia, y genera
  un JSON compacto con:
  - `generated_at`, `valid_from`, `valid_to`
  - paradas: id, nombre, lat, lon, líneas que la sirven
  - viajes de los **próximos 7 días**: trip_id, línea, destino (headsign o última parada), fechas en que circula,
    y horas de paso por parada.
- Publicado en GitHub Pages (servido con gzip). Objetivo de tamaño < 1 MB sin comprimir; el formato concreto
  (p. ej. agrupar viajes con mismo patrón de horas) es decisión del builder.
- Cron diario de madrugada (hora de Madrid) + ejecución manual (`workflow_dispatch`).
- Si la descarga o validación falla (p. ej. 0 viajes C1/C2), **no** sobrescribe el JSON publicado y la Action falla
  (GitHub avisa por email).
- Tests del script con un mini-GTFS de fixture.

### 2. App Flutter (iOS + Android)

- Al arrancar: carga el JSON cacheado en disco (si existe) → pinta enseguida; en paralelo descarga el JSON nuevo
  si el cacheado es de otro día o tiene > 12 h.
- Ubicación: pide permiso "mientras se usa" y obtiene una posición al abrir y al volver a primer plano. No hay
  seguimiento en segundo plano.
- Estación: la parada C1/C2 más cercana (distancia en línea recta). Se muestra la distancia. Si el usuario toca el
  nombre, puede elegir otra de la lista; esa elección manual se mantiene hasta que se cierre la app (decisión mía,
  ajustable). Sin permiso de ubicación → lista para elegir, y se recuerda la última elegida.
- Tiempo real: consulta `trip_updates.json` al abrir y cada 30 s mientras la app está en primer plano. Para cada viaje
  aplica su `delay` a la hora prevista en la estación del usuario.
- Pantalla: dos bloques, uno por sentido ("→ València Nord" y "→ Gandia / Moixent"), con 3 próximos trenes cada uno:
  etiqueta de línea con su color oficial (C1 `#7AB3DE`, C2 `#F79529`), minutos que faltan, hora prevista y retraso
  (+N / −N), indicador "en vivo" o "previsto", y "Cancelado" si aplica. Pie con "actualizado hace X s" y "Datos: Renfe".
- Errores: sin red → datos cacheados y aviso discreto de "sin tiempo real". Horario que no cubre hoy → aviso claro.
- Idioma español; modo claro/oscuro del sistema.

```
┌───────────────────────────────┐
│  📍 Silla              (350 m) │
│  → València Nord               │
│   C1   4 min   18:52 (+2)      │
│   C2  11 min   18:59  previsto │
│   C1  27 min   19:15           │
│  → Gandia / Moixent            │
│   C2   6 min   18:54 (+7)      │
│   C1  19 min   19:07           │
│   C1  ✕ Cancelado  19:22       │
│  actualizado hace 12 s · Datos: Renfe │
└───────────────────────────────┘
```

### 3. Distribución

- iOS: build firmado con la cuenta de Apple Developer del usuario → App Store Connect → TestFlight (testers internos).
  Requiere bundle id propio y textos de permiso de ubicación en `Info.plist`.
- Android: APK release firmado con keystore propio (guardado fuera del repo) para enviar a mano.
- El nombre y el icono no deben imitar la marca Renfe.

## Reglas concretas (decididas tras la revisión del diseño)

- **"En vivo" vs "previsto"**: un tren es "en vivo" si su `trip_id` aparece en el último `trip_updates.json`
  descargado y esa descarga tiene < 2 min. Si no aparece, es "previsto" (no se interpreta como cancelado).
  Si la última descarga correcta de RT tiene > 2 min, todos pasan a "previsto" y se muestra "sin tiempo real".
- **Caducidad del horario**: aviso si el JSON local no cubre la fecha de hoy, o si `generated_at` tiene > 3 días.
  Se intenta descargar uno nuevo al abrir si el cacheado no es del día (hora de Madrid) o tiene > 12 h.
- **Zona horaria y día de servicio**: todo en `Europe/Madrid`. Se usa la semántica GTFS: un viaje pertenece a
  su día de servicio y las horas ≥ 24:00 caen en la madrugada del día siguiente. Para "ahora" hay que mirar los
  viajes de hoy y también los de ayer con horas ≥ 24:00.
- **Validación del pipeline**: no publica si falta alguna de las líneas C1 o C2, si hay < 20 paradas, o si
  los datos no cubren hoy y mañana. En esos casos la Action falla.
- **Estación manual vs GPS**: si el usuario eligió una estación a mano, volver a primer plano no la cambia
  durante esa sesión de la app. Si no la eligió, se recalcula por GPS cada vez que vuelve a primer plano.
- **Red**: timeout de 10 s para el RT, reintento en el siguiente ciclo de 30 s y sin más backoff.
  Si el feed llega bien pero no trae ningún viaje C1/C2, no es un error: todos los trenes salen como "previsto".
- **Trenes que acaban en estaciones intermedias** (decisión del usuario): se muestran en su bloque de sentido
  con el destino real ("C2 6 min → Xàtiva"). Cada bloque enseña los 3 próximos trenes, sean de C1 o de C2.
  El sentido se decide comparando la posición de la parada del usuario con la del destino del viaje dentro de
  la línea. El detalle de cómo hacerlo queda para el builder.
- **Repositorio** (decisión del usuario): repo público en GitHub, con el JSON servido por GitHub Pages.
  Keystores, certificados y perfiles de firma nunca se suben al repo.
- **URL del horario**: es la que usan los proyectos de la comunidad y la que figura en datos.gob.es.
  Comprobada el 2026-11-15.

## Para el builder

- Formato exacto del JSON, cómo se determina el "sentido" de cada viaje (dirección GTFS o destino final), y cómo
  mostrar los trenes de la C1/C2 que acaban en estaciones intermedias.
- Cómo comportarse si el `delay` del RT se refiere a una parada ya pasada por el usuario (aplicar el mismo retraso
  a la parada del usuario es aceptable).
- Mostrar o no alertas de `alerts.json` filtradas a C1/C2 (deseable pero opcional en v1).
- Gestión de estado, estructura del proyecto y paquetes de Flutter.
- Ventana para considerar que un tren "ya pasó" (p. ej. ocultarlo 1 min después de su hora estimada).
