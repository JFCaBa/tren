# Andén: notes for App Review (answer to Guideline 2.1, 16-11-2026)

Paste the text below into App Store Connect → Andén → version 1.0 → App Review Information → Notes,
attach the screen recording, and resubmit.

---

1. SCREEN RECORDING
Attached: a recording made on an iPhone running the latest iOS. It starts by launching the app from the Home Screen and shows the typical flow: allowing location, the nearest station with its next trains, opening a train to see its remaining stops, choosing another station by hand and setting a destination filter. The app has no accounts, no login, no user-generated content and no paid content or in-app purchases.

2. PURPOSE AND AUDIENCE
Andén answers one question for commuters on Spain's suburban rail network (Renfe Cercanías / Rodalies): "how long until my train?". It opens on the nearest station and lists the next departures in both directions with real-time delays and cancellations. It is for everyday passengers in Madrid, Barcelona, Valencia, Bilbao, Seville and the other Cercanías networks, who today have to dig through timetables or a general-purpose rail app to get this one answer. It is a non-commercial project: the app is free, with no ads, no in-app purchases, no analytics and no accounts.

3. HOW TO USE IT
No account or credentials are needed.
- Open the app. If location is allowed, it shows the nearest Cercanías station.
- Location is optional. If it is denied (or the reviewer is outside Spain), tap "Elegir estación" and pick any station, for example "Atocha" in the Madrid group. To change station at any time, tap the station name at the top.
- Tap a train to see its remaining stops and times.
- Tap a destination chip above the list to filter the board ("Todos" clears it); the app remembers the filter for that station.
- Between about 00:00 and 05:00 Spanish time there is no service, so the board shows the first trains of the morning.
The interface is in Spanish.

4. EXTERNAL SERVICES
- Renfe open data: the scheduled timetable (GTFS, ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip) and real-time delays (GTFS-RT, gtfsrt.renfe.com/trip_updates.json), which the app reads directly.
- GitHub Pages (jfcaba.github.io/tren): hosts the timetable files our pipeline builds from Renfe's GTFS, plus the support and privacy pages.
- Apple Core Location, used only on the device to find the nearest station; the location is never sent anywhere.
No authentication, payment, advertising, analytics or AI services are used.

5. REGIONAL DIFFERENCES
The app works the same way in every region. Its content covers Spanish Cercanías stations only, so outside Spain the nearest-station feature has nothing nearby to show; choosing a station by hand works everywhere.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
The app does not operate in a regulated industry and is non-commercial. It is an independent, unofficial app with no relationship to Renfe, and says so in its description; it uses no Renfe logos or trademarks.
All data comes from datasets Renfe publishes on its open data portal under the Creative Commons Attribution 4.0 licence (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/), which allows reuse for any purpose, with attribution:
- Timetables (GTFS): https://data.renfe.com/dataset/horarios-cercanias
- Real-time delays (GTFS-RT trip updates): https://data.renfe.com/dataset/horarios-viaje-cercanias
Portal reuse terms: https://data.renfe.com/legal
As the licence requires, the app credits the source on its main screen ("Datos: Renfe"), as do its support and privacy pages.
