# Andén: estado en las tiendas (16-11-2026)

## App Store (iOS)

- App 6835200430, "Andén · Próximo tren", cuenta 338 TAC, S.L.
- Versión 1.0: ficha completa, capturas de iPhone 6,3" (1206×2622; App Store Connect ya no acepta 6,9" como tamaño principal) y privacidad "Datos no recogidos".
- Build 9 (con el enlace "Privacidad") subido; **hay que seleccionarlo en la versión 1.0 en lugar del 8** cuando termine de procesarse.
- Pendiente del usuario: contacto de App Review (nombre, email y teléfono).
- Después: "Add for Review" (solo con confirmación del usuario). Publicación manual tras la aprobación.

## Google Play (Android)

- Cuenta "Jose Catala" (jfcaba68@). La otra cuenta personal (jfca68@) está cerrada desde 2024.
- App "Andén", `com.jfcaba.proximotren`, gratuita, Viajes y guías, PEGI 3.
- Prueba cerrada "Alpha": versión 9 (1.0.0), España, lista "Beta testers" (22 personas, la misma de LocalGuideApp), feedback en la página de soporte.
- **Enviada a revisión el 16-11-2026.** La publicación gestionada está desactivada: al aprobarse, la prueba se activa sola.

### Después de la aprobación

1. Copiar el enlace de participación (Prueba cerrada → Alpha → Testers → "Join on Android / on the web") y mandarlo a los probadores.
2. Cada probador tiene que **aceptar** la invitación con el enlace e instalar la app desde Play.
3. Los 14 días cuentan desde que hay **≥ 12 probadores inscritos** y deben ser seguidos. Se sigue en el Panel → "Closed testing" (contador de probadores y días).
4. Pasados los 14 días: Panel → "Apply for production" (responde a unas preguntas sobre la prueba), y después crear la versión de producción.

## Próximas mejoras propuestas

- Vía/andén en tiempo real: `gtfsrt.renfe.com/vehicle_positions.json` incluye `PLATF.(N)` en `vehicle.label` para la parada `stopId` a la que se dirige el tren (≈ 60 % de los trenes).
