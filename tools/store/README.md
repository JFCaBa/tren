# Store screenshots and app preview (style B: departure board)

All screens come from the real app driven by `app/integration_test/store_test.dart`: a fixed clock
(Friday 20-11-2026, 08:12), Renfe's real Madrid timetable and chosen realtime data (one train late,
one canceled, live platforms). Re-run it whenever the UI changes.

1. Data: copy `index.json` and `feed_10.json` (from the app cache on a simulator, or from GitHub Pages
   `feeds/10.json`) into a folder `DATA` (absolute path: the app on the simulator reads it directly). The feed must cover 20-11-2026, or change the date in the test.
2. Simulator: iPhone 6.3" (1206x2622), dark appearance, `xcrun simctl status_bar <udid> override --time 8:13`.
3. Screenshots: `capture.sh <log> <work>/raw <udid> &` then
   `flutter test integration_test/store_test.dart -d <udid> --dart-define=DEMO_DATA=DATA > <log>`
   (from `app/`). Then `python3 compose_screenshots.py <work>` writes `<work>/final/{ios-6.9,ios-6.3,android}`.
4. Preview: same, with `record.sh <log> <work>/video <udid> &`, then `make_preview.sh <work>/video`.

Outputs live in `docs/store/screenshots/` and `docs/store/preview/`. Needs Chrome, ImageMagick and ffmpeg.
