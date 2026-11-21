# Andén 1.4: hora de llegada, widget e incidencias (diseño)

## Por qué
Ideas para la siguiente versión sin perder la sencillez (21-11-2026). El usuario eligió: (1) la hora de llegada a su
destino, (2) un widget en la pantalla de inicio, y pidió mirar (3) las incidencias de Renfe.

## Decidido con el usuario
- Destino: los chips de destino final siguen como están; al final de la fila, un chip **«Otra parada…»**
  abre una búsqueda limitada a las paradas a las que se llega desde esta estación. Al elegir, p. ej., Sol,
  solo salen los trenes que paran en Sol, cada uno con **«llega a Sol 08:34»**. Se recuerda por estación,
  como el filtro actual.

## Datos de las incidencias (mirado el 21-11-2026)
`https://gtfsrt.renfe.com/alerts.json` (GTFS-RT, 68 KB, 77 avisos). Cada aviso trae `activePeriod`
(solo `start`; ninguno trae `end`), `informedEntity` (`routeId` como `10T0013C4a` = núcleo 10 + línea
C4a, o `stopId` como `18101` = Sol) y `descriptionText` en español. Sin `headerText`, `cause` ni
`effect`. Ejemplos: reajustes de servicio en una línea, obras con fechas, ascensores fuera de servicio,
estación inaccesible. El texto de línea empieza con una etiqueta tipo `#MadC4a`.

## Lo que ve el usuario (decisiones de Claude)

### 1. Llegada a tu destino
- Chip «Otra parada…» al final de la fila de destinos. Abre una hoja con buscador (igual que el selector
  de estación) con las paradas que vienen después de esta estación en algún tren de hoy, por nombre.
- Elegida una parada, el chip pasa a «→ Sol» marcado. Es excluyente con los chips de destino final:
  elegir una parada quita los destinos marcados y marcar un destino quita la parada. «Todos» quita todo.
- Lista y tarjeta grande: solo trenes que paran en esa parada después de esta estación; debajo del
  destino, «llega a Sol 08:34» (hora estimada: con el retraso en vivo si lo hay).
- Con un solo destino final marcado también se ve «llega a Chamartín 08:52». Con varios, nada.
- Se guarda por estación (`via_<stopId>`); si la parada ya no existe en el horario, se olvida.

### 2. Widget
- iOS (WidgetKit, en la extensión existente `FollowActivity`) y Android (AppWidget), tamaño pequeño y
  mediano en iOS, uno de 4×2 en Android.
- Muestra la última estación que abriste: nombre y los próximos trenes (3 en pequeño, 4 en mediano y
  Android): línea con su color, destino, hora y vía (rellena en vivo, con borde habitual, como en la app);
  el retraso en ámbar; los cancelados atenuados. Con destino o parada elegidos, respeta el filtro y
  muestra la hora de llegada en lugar del destino final cuando hay parada elegida.
- iOS: cuenta atrás que el propio iOS mantiene al día. Android: hora de salida (sin cuenta atrás, porque
  Android solo deja refrescar el widget cada 30 min).
- Datos: la app guarda los próximos 8 trenes de la estación cada vez que calcula el tablero (con
  `home_widget`, App Group `group.com.jfcaba.proximotren` en iOS). El widget descarta los que ya
  salieron; sin trenes que mostrar dice «Abre Andén para ver los próximos trenes». No hay refresco en
  segundo plano en esta versión: el widget se pone al día al abrir la app.
- Tocar el widget abre la app.

### 3. Incidencias
- La app lee `alerts.json` de Renfe directamente, como los otros feeds en tiempo real, como mucho cada
  5 min y solo con la app abierta.
- Un aviso es de tu estación si su `stopId` es la estación o si su `routeId` (núcleo + línea) es una
  línea que pasa por ella. Solo avisos ya empezados (`start` ≤ ahora; si traen `end`, que no haya pasado).
- Bajo el nombre de la estación, junto a «En vivo», una línea ámbar «⚠ 2 avisos de Renfe». Al tocarla,
  una hoja con cada aviso: chip de la línea (si es de línea) y el texto sin la etiqueta `#MadC4a`.
- Sin avisos, nada. Si el feed falla, nada (no es crítico).
- No entra en el widget ni en las notificaciones.

## Técnica
- `computeBoard` recibe `via` (stopId) y cada `Departure` gana `arrival: StopTime?` (llegada a la parada
  elegida, o al destino final cuando hay un único destino marcado).
- Paradas alcanzables: de los trips del feed de la estación que pasan hoy por ella, las paradas posteriores.
- Incidencias: `lib/data/alerts.dart` (parseo tolerante) y `lib/domain/alerts.dart` (`alertsFor`).
- Widget: paquete `home_widget`; snapshot JSON con `station`, `updatedAt` y trenes
  `{line, color, dest, dep (epoch s), sched (epoch s), platform, live, canceled, arrival?}`; Swift
  `NextTrainsWidget` en la extensión `FollowActivity` (bundle), Kotlin `NextTrainsWidgetProvider`.
- iOS: App Group en Runner y FollowActivity (entitlements y App ID; firma automática).
- Versión 1.4.0+16. Política de privacidad: sin cambios (el widget guarda datos solo en el móvil; los
  avisos vienen de Renfe sin enviar nada).

## No entra
Refresco del widget en segundo plano, widget de tu tren seguido, avisos de incidencias por notificación,
varias paradas de destino a la vez, transbordos.

## Enfoques considerados
- Destino: chip «Otra parada…» (elegido) frente a mostrar solo la llegada al destino final (no sirve a
  quien se baja antes, que es la mayoría).
- Widget con datos que deja la app (elegido) frente a widget que calcula el horario por su cuenta en
  Swift/Kotlin (duplicaría la lógica del tablero) o que descarga datos en segundo plano (más
  complejo, y iOS lo limita igualmente).
- Incidencias leídas por la app (elegido) frente a pasarlas por nuestro servidor (sin necesidad:
  el feed es público y pequeño).
