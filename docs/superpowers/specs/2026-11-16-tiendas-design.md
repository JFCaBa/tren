# Andén: preparación para las tiendas (diseño)

Fecha: 2026-11-16. Parte de la app multinúcleo ya terminada (build 7 en TestFlight).

## Intención

Publicar gratis la app en App Store y Google Play con identidad propia, para todos los núcleos de Cercanías.

## Decisiones del usuario

- **Nombre:** **Andén**. Si "Andén" está cogido en App Store Connect, se usa "Andén · Próximo tren".
- **Icono:** propuesta **B · Cuenta atrás**: tren blanco dentro de un anillo blanco que se va cerrando, sobre verde azulado `#0F766E` con anillo de fondo `#134E4A`. Diseño fuente en `.superpowers/brainstorm/…/icono-anden.html`.
- **Precio:** app gratuita, sin anuncios ni compras.
- **Contacto público:** jfca68@gmail.com (en las fichas de las tiendas, la política de privacidad y la página de soporte).
- **Plataformas:** solo vertical. En iOS, solo iPhone (ya hecho en `d9fb148`).
- **Google Play:** la cuenta personal jfcaba68@ obliga a una prueba cerrada con ≥ 12 probadores durante 14 días antes de pasar a producción. El usuario aporta los probadores.

## Decisiones de Claude (corregibles)

- **Identificadores:** bundle id / applicationId sin cambios (`com.jfcaba.proximotren`), porque no se ven y cambiarlos obligaría a crear otra ficha. Se cambia el nombre visible a "Andén" en iOS (`CFBundleDisplayName`) y en Android (`android:label`).
- **Categoría:** Viajes (iOS y Android). Clasificación por edades: para todos los públicos.
- **Textos en español (España):**
  - Subtítulo: "Próximo tren de Cercanías".
  - Palabras clave: cercanías, tren, rodalies, horarios, retrasos, estación, tiempo real. Sin "Renfe": Apple no admite marcas ajenas en las palabras clave.
  - Descripción: qué hace, ciudades cubiertas, "Datos: Renfe (datos abiertos)" y la aclaración de que es una app no oficial, sin relación con Renfe.
- **Privacidad:** "Datos no recogidos" en App Store y "No se recogen ni comparten datos" en Google Play. La ubicación solo se usa en el dispositivo.
- **Páginas web:** `privacidad.html` y `soporte.html`, publicadas con el horario en GitHub Pages (`https://jfcaba.github.io/tren/…`). La Action las copia en `site/`.
- **Icono:**
  - Generado desde SVG con un script del repo (`tools/icon/`) que produce el PNG de 1024 px y los tamaños de iOS (`AppIcon.appiconset`).
  - Android: icono adaptativo (fondo `#0F766E` y primer plano con anillo y tren) más el `mipmap` heredado, y 512 px para Play.
  - Sin dependencias nuevas en la app.
- **Capturas:**
  - iPhone 6,9" (1320×2868), obligatorias, en el simulador iPhone 17 Pro Max.
  - Android teléfono (1080×1920 o superior).
  - 3–4 capturas: Valencia (Silla) con filtros, Madrid (Atocha) con tiempo real, paradas desplegadas y Rodalies (Barcelona Sants).
  - Sin textos promocionales superpuestos en esta versión.
- **Gráfico destacado de Play** (1024×500): icono más el nombre "Andén" sobre el verde de marca.
- **App Store Connect:** renombrar la ficha "Próximo Tren VLC" → "Andén", rellenar ficha, privacidad, URLs y capturas, y enviar el build a revisión **solo con el visto bueno del usuario**.
- **Google Play Console:** crear la app, la ficha, la prueba cerrada, la seguridad de datos y la clasificación de contenido, y subir el AAB firmado con la clave de subida. Requiere que la sesión de Play Console esté abierta en Chrome. Las acciones que publican o envían a revisión se confirman con el usuario.
- **Android:** se publica el App Bundle (`flutter build appbundle`), además del APK para uso directo.

## Fuera de alcance

- Capturas de iPad, otros idiomas y textos promocionales sobre las capturas.
- La fase de producción en Google Play: se hará cuando terminen los 14 días.
