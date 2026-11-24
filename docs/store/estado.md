# Andén: estado en las tiendas (actualizado 18-11-2026)

## App Store (iOS)

- App 6835200430, "Andén · Próximo tren", cuenta 338 TAC, S.L.
- Versión 1.0: ficha completa, capturas de iPhone 6,3" (1206×2622; App Store Connect ya no acepta 6,9" como tamaño principal) y privacidad "Datos no recogidos".
- Versión 1.0 **enviada a revisión** por el usuario el 16-11-2026. Publicación manual tras la aprobación.
- 16-11-2026: Apple pidió información (guideline 2.1). Respondido con las notas de `review-notes-en.md` y una grabación en iPhone, notas copiadas en App Review Information y **reenviada**: Waiting for Review.
- **Build 12 = versión 1.1.0 (vía + búsqueda de estaciones por nombre + más trenes con scroll / «Ver más»)** subido a App Store Connect el 18-11-2026 (sustituye al build 11). Se envía a revisión como versión 1.1 cuando la 1.0 esté aprobada (con confirmación del usuario). Novedades en `listing-es.md`. Notas para el revisor: añadir el dataset `ubicacion-vehiculos` (CC BY 4.0) que usa la vía en vivo.

- 19-11-2026: la 1.0 ya está en la App Store. **Versión 1.1.0 preparada** en App Store Connect con el build 12: descripción nueva (vía, búsqueda, «Ver más», FUENTE data.renfe.com, aviso "ni con ningún organismo público"), novedades, notas del revisor 1.1 (`review-notes-en.md`, sin grabación) y **publicación manual**. Falta que el usuario pulse "Add for Review"; se publica la semana del 23-11-2026.

- 19-11-2026: **capturas y vista previa nuevas para la 1.2** (estilo "panel de andén"): `docs/store/screenshots/{ios (6,9"),ios-6.3,android}` (5 cada una) y `docs/store/preview/preview-886x1920.mp4` (29,7 s). Se suben al preparar la versión 1.2 (en App Store Connect las capturas van con cada versión). Cómo regenerarlas: `tools/store/README.md`.
- 19-11-2026: **versión 1.2.0 en App Store Connect** rellenada: 5 capturas nuevas (6,3", sustituyen a las 4 de la 1.0; las antiguas siguen en la biblioteca de recursos), vista previa en vídeo, header de la biblioteca, texto promocional, descripción, novedades (`listing-es.md`), notas del revisor 1.2 (`review-notes-en.md`) y publicación manual. Build **1.2.0 (14)** subida el 19-11-2026 (y AAB 1.2.0 (14) compilado para Play). Header nuevo estilo panel (`tools/icon/header-b.html`, `header-b-5244x2950.png`) en lugar del teal. Enviada a revisión por el usuario el 19-11-2026: **Waiting for Review**, publicación manual (semana del 23-11-2026).

## Google Play (Android)

- Cuenta "Jose Catala" (jfcaba68@). La otra cuenta personal (jfca68@) está cerrada desde 2024.
- App "Andén", `com.jfcaba.proximotren`, gratuita, Viajes y guías, PEGI 3.
- Prueba cerrada "Alpha": versión 9 (1.0.0), España, lista "Beta testers" (22 personas, la misma de LocalGuideApp), feedback en la página de soporte.
- **Enviada a revisión el 16-11-2026.** La publicación gestionada está desactivada: al aprobarse, la prueba se activa sola.

- **Versión 1.1.0 (11)**: subida a la prueba cerrada "Alpha" con notas es-ES y **enviada a revisión el 17-11-2026** (la 9 ya no se incluye).
- La 11 se aprobó y publicó en Alpha el 17-11-2026 (publicación gestionada desactivada).
- **Versión 1.1.0 (13)** (18-11-2026): más trenes con scroll / «Ver más» + `screen.portrait` no obligatoria (+7 tablets, +3 TV).
  AAB subido por el usuario, notas es-ES, vista previa "Ready to release"; guardada en Publishing overview, **sin enviar**:
  **enviada a revisión por el usuario el 18-11-2026**. Al aprobarse se publica sola en Alpha (publicación gestionada off).
- **Versión 1.2.0 (14)** (19-11-2026): ficha actualizada (descripción 1.2, 5 capturas nuevas estilo panel, gráfico destacado `tools/icon/feature-b-1024x500.png`) guardada; borrador de versión en Alpha con notas es-ES. Falta: el usuario arrastra el AAB, "Next"/"Save" y envía los cambios a revisión desde Publishing overview.
- Probadores: listas "Alpha testers" (5) y "Beta testers" (22), 23 direcciones distintas.
  Enlace web: https://play.google.com/apps/testing/com.jfcaba.proximotren

### Después de la aprobación

1. Copiar el enlace de participación (Prueba cerrada → Alpha → Testers → "Join on Android / on the web") y mandarlo a los probadores.
2. Cada probador tiene que **aceptar** la invitación con el enlace e instalar la app desde Play.
3. Los 14 días cuentan desde que hay **≥ 12 probadores inscritos** y deben ser seguidos. Se sigue en el Panel → "Closed testing" (contador de probadores y días).
   - 21-11-2026: 2 probadores inscritos en Android; el usuario espera llegar a 12 la semana del 23-11-2026.
4. Pasados los 14 días: Panel → "Apply for production" (responde a unas preguntas sobre la prueba), y después crear la versión de producción.

## Vía (1.1)

- Recolector `platforms.yml` cada 10 min → rama `platform-data` (`platforms.json` + copia diaria `platforms-prev.json`). Si falla, GitHub avisa por email.
- Vía habitual: necesita ≥ 2 días de observaciones; a partir del 18-11 empiezan a aparecer, útil en ~2 semanas.
- Vigilar: tamaño de `platforms.json` (varios MB previstos) y de los feeds (+~10 % con cobertura completa).

## 1.3.0 (15) — seguir un tren (21-11-2026)

- iOS: build 15 probado en iPhone por el usuario (Live Activity y avisos OK). ASC 1.3.0 guardada con build 15, novedades,
  descripción con «Sigue tu tren» y notas de revisión 1.3.0 (review-notes-en.md). App Privacy «Device ID · Not Linked ·
  App Functionality · no tracking» rellenada; el usuario pulsa Publish y luego «Add for Review» / enviar.
- Play: Alpha 15 (1.3.0) guardada con notas es-ES; declaración FGS dataSync (Network processing → Other, vídeo
  https://youtube.com/shorts/1Nkh9f6hwvY). Enviada a revisión por el usuario (21-11-2026).
- Servidor de seguimiento: https://api.whatplatform.uk/anden/ (contenedor en el VPS, `tren/server/`).

## 1.4.0 (16) — llegada, widget, avisos de Renfe (21-11-2026)

- Código en main (24635ed). iOS build 16 subido a App Store Connect (App Group `group.com.jfcaba.proximotren` en app y
  extensión). AAB 1.4.0 (16) en `app/build/app/outputs/bundle/release/app-release.aab`.
- Pendiente: probar el widget en iPhone (TestFlight); enviar 1.4 cuando Apple y Google aprueben la 1.3 (no
  reiniciar sus revisiones). Novedades en listing-es.md.

## 1.4.0 (18) — widget con vista previa y refresco solo (22-11-2026)

- Galería de widgets con ejemplo (Atocha) en iOS y Android. El widget descarga él mismo el tiempo real de Renfe
  (iOS cuando lo decide el sistema, pedido cada 15 min; Android con WorkManager cada 15 min) y la app le deja 60
  trenes. Sin abrir Andén en un día se acaban los trenes. La vía la sigue poniendo la app.
- Sustituye a las builds 16 y 17 para enviar la 1.4 (misma versión, mismas novedades). Widget pequeño: solo línea y hora (4 trenes).

## 1.4.0 (19) — botón ⓘ con versión, datos y privacidad (22-11-2026)

- iOS build 19 subido a App Store Connect. AAB 1.4.0 (19) subido por el usuario a una release nueva de Alpha
  ("19 (1.4.0)", notas es-ES de la 1.4), enviada a revisión por el usuario el 22-11-2026.
  Sustituye a la 18 para enviar la 1.4.

## 1.5.0 (20) — horarios y tiempo real desde nuestro servidor, estadísticas (24-11-2026)

- Horarios en `api.whatplatform.uk/anden/data` (Pages de reserva), tiempo real por estación en
  `/anden/live/<estación>` (Renfe directo de reserva) y recuento anónimo para `/anden/admin`.
  Política de privacidad actualizada (sección «Estadísticas anónimas»).
- iOS: build 20 subido; ASC 1.5.0 creada con build 20, novedades y notas de revisión 1.5 (sin
  «no analytics»: totales anónimos en nuestro servidor). App Privacy: sin cambios por ahora
  (totales no ligados a persona ni dispositivo; decide el usuario). Falta: «Add for Review» (usuario).
- Play: release nueva en Alpha con notas es-ES de la 1.5; AAB 1.5.0 (20) en
  `app/build/app/outputs/bundle/release/app-release.aab` (54 MB, lo arrastra el usuario). Falta:
  subir AAB, Next y enviar a revisión (usuario).
- Enviada a revisión por el usuario y **aprobada** (24-11-2026).

## 1.5.1 (21) — nombre de estación en dos líneas (24-11-2026)

- Los nombres largos (p. ej. «Barcelona-Passeig de Gràcia») ya no se cortan con «…»: el título
  de la estación ocupa hasta dos líneas.
- iOS: build 21 subido a App Store Connect / TestFlight (24-11-2026).
- Play: borrador de release en Alpha con notas es-ES de la 1.5.1; AAB 1.5.1 (21) en
  `app/build/app/outputs/bundle/release/app-release.aab` (54 MB, lo arrastra el usuario).
