# Andén: estado en las tiendas (actualizado 16-11-2026)

## App Store (iOS)

- App 6835200430, "Andén · Próximo tren", cuenta 338 TAC, S.L.
- Versión 1.0: ficha completa, capturas de iPhone 6,3" (1206×2622; App Store Connect ya no acepta 6,9" como tamaño principal) y privacidad "Datos no recogidos".
- Versión 1.0 **enviada a revisión** por el usuario el 16-11-2026. Publicación manual tras la aprobación.
- 16-11-2026: Apple pidió información (guideline 2.1). Respondido con las notas de `review-notes-en.md` y una grabación en iPhone, notas copiadas en App Review Information y **reenviada**: Waiting for Review.
- **Build 10 = versión 1.1.0 (vía)** subido a App Store Connect: disponible en TestFlight cuando se procese. Se envía a revisión como versión 1.1 cuando la 1.0 esté aprobada (con confirmación del usuario). Novedades en `listing-es.md`.

## Google Play (Android)

- Cuenta "Jose Catala" (jfcaba68@). La otra cuenta personal (jfca68@) está cerrada desde 2024.
- App "Andén", `com.jfcaba.proximotren`, gratuita, Viajes y guías, PEGI 3.
- Prueba cerrada "Alpha": versión 9 (1.0.0), España, lista "Beta testers" (22 personas, la misma de LocalGuideApp), feedback en la página de soporte.
- **Enviada a revisión el 16-11-2026.** La publicación gestionada está desactivada: al aprobarse, la prueba se activa sola.

- **Versión 1.1.0 (10)**: AAB en `app/build/app/outputs/bundle/release/app-release.aab` (firmado). Lo sube el usuario (> 10 MB) a la prueba cerrada "Alpha" cuando Google apruebe la 1.0; confirmar antes de enviar a revisión.

### Después de la aprobación

1. Copiar el enlace de participación (Prueba cerrada → Alpha → Testers → "Join on Android / on the web") y mandarlo a los probadores.
2. Cada probador tiene que **aceptar** la invitación con el enlace e instalar la app desde Play.
3. Los 14 días cuentan desde que hay **≥ 12 probadores inscritos** y deben ser seguidos. Se sigue en el Panel → "Closed testing" (contador de probadores y días).
4. Pasados los 14 días: Panel → "Apply for production" (responde a unas preguntas sobre la prueba), y después crear la versión de producción.

## Vía (1.1)

- Recolector `platforms.yml` cada 10 min → rama `platform-data` (`platforms.json` + copia diaria `platforms-prev.json`). Si falla, GitHub avisa por email.
- Vía habitual: necesita ≥ 2 días de observaciones; a partir del 18-11 empiezan a aparecer, útil en ~2 semanas.
- Vigilar: tamaño de `platforms.json` (varios MB previstos) y de los feeds (+~10 % con cobertura completa).
