# Andén: notes for App Review

## 1.3.0

Paste into App Store Connect → Andén → version 1.3.0 → App Review Information → Notes (limit 4000 characters).

---

1. PURPOSE AND AUDIENCE
Andén answers one question for commuters on Spain's suburban rail (Renfe Cercanías): "how long until my train?". It opens on the nearest station and lists the next departures with real-time delays and cancellations. Non-commercial: free, no ads, no in-app purchases, no analytics, no accounts.

2. HOW TO USE IT
No account is needed. The interface is in Spanish.
- Open the app. With location allowed it shows the nearest station; otherwise (or outside Spain) tap "Elegir estación" and pick e.g. "Atocha" in the Madrid group. Tap the station name to change station or search by name.
- The next train is in a large card; platforms ("vía") are filled when live, outlined when usual. Delays show the scheduled time struck out; canceled trains are dimmed.
- Tap a train to see its stops. Destination chips filter the board. "Ver más" loads more trains.
- NEW IN 1.3, follow a train: long-press any train (or tap it, then "Seguir este tren"). A bar says "Siguiendo …" with "Deshacer" (undo); the train moves to the large card with a bell and a line saying where it is (e.g. "En Getafe Centro · a 3 paradas"). On iOS 16.1+ a Live Activity shows on the Lock Screen and Dynamic Island with countdown, delay status, platform and position. The app asks for notification permission the first time. While followed, a notification is sent if the platform appears or changes, the delay changes by 2 minutes or more, or the train is canceled, also with the app closed. Long-press again (or "Dejar de seguir") to stop; following ends 2 minutes after the train leaves. One train at a time. Alerts depend on what Renfe publishes live, so a train without changes shows only the Live Activity.
- Looking at another station while following, a "Tu tren" strip at the top keeps showing it.
- Between about 00:00 and 05:00 Spanish time there is no service; the board shows the first morning trains.

3. EXTERNAL SERVICES
- Renfe open data: timetable (GTFS), real-time delays (gtfsrt.renfe.com/trip_updates.json) and vehicle positions (gtfsrt.renfe.com/vehicle_positions.json), read directly by the app.
- GitHub Pages (jfcaba.github.io/tren): timetable files built from Renfe's GTFS, support and privacy pages.
- Our follow service (api.whatplatform.uk/anden), only while a train is followed on iPhone: the app sends the train id, station, scheduled time, its stops and the APNs push token (and Live Activity token); the service polls Renfe's real-time data and sends alerts and Live Activity updates via Apple Push Notification service. Tokens are kept in memory only, never logged, deleted when following ends. No personal data, account or location is sent.
- Apple Core Location, on the device only, to find the nearest station; never sent anywhere.
No authentication, payment, advertising, analytics or AI services.

4. REGIONAL DIFFERENCES
Same in every region. Content covers Spanish stations only; choosing a station by hand works everywhere.

5. THIRD-PARTY MATERIAL
Not a regulated industry; non-commercial. Independent, unofficial app with no relationship to Renfe (stated in the description); no Renfe logos or trademarks.
All data comes from Renfe open data under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/):
- https://data.renfe.com/dataset/horarios-cercanias
- https://data.renfe.com/dataset/horarios-viaje-cercanias
- https://data.renfe.com/dataset/ubicacion-vehiculos
Reuse terms: https://data.renfe.com/legal
The app credits the source on its main screen ("Datos: Renfe") and on its support and privacy pages.

## 1.2.0

Paste into App Store Connect → Andén → version 1.2.0 → App Review Information → Notes.

---

1. PURPOSE AND AUDIENCE
Andén answers one question for commuters on Spain's suburban rail network (Renfe Cercanías / Rodalies): "how long until my train?". It opens on the nearest station and lists the next departures in both directions with real-time delays and cancellations. It is for everyday passengers in Madrid, Barcelona, Valencia, Bilbao, Seville and the other Cercanías networks, who today have to dig through timetables or a general-purpose rail app to get this one answer. It is a non-commercial project: the app is free, with no ads, no in-app purchases, no analytics and no accounts.

2. HOW TO USE IT
No account or credentials are needed.
- Open the app. If location is allowed, it shows the nearest Cercanías station, with the next train in a large card at the top and the following trains below.
- Location is optional. If it is denied (or the reviewer is outside Spain), tap "Elegir estación" and pick any station, for example "Atocha" in the Madrid group. To change station at any time, tap the station name at the top.
- To find a station by name, tap the station name at the top and type in the search box (e.g. "Sol").
- Each train shows its platform ("vía") in a pill: filled when Renfe publishes it live, outlined when it is the usual one for that train.
- Delays show the scheduled time struck out next to the new one (amber from 3 minutes); canceled trains are dimmed. "En vivo" under the station name says real-time data is on.
- Scroll to the end of the list, or tap "Ver más", to load more trains.
- Stations used recently appear as shortcuts under the station name; tap one to switch.
- Tap a train to see its remaining stops and times.
- Tap a destination chip above the list to filter the board ("Todos" clears it); the app remembers the filter for that station.
- Between about 00:00 and 05:00 Spanish time there is no service, so the board shows the first trains of the morning.
The interface is in Spanish.

3. EXTERNAL SERVICES
- Renfe open data: the scheduled timetable (GTFS, ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip), real-time delays (GTFS-RT, gtfsrt.renfe.com/trip_updates.json) and vehicle positions, used for the live platform (gtfsrt.renfe.com/vehicle_positions.json), which the app reads directly.
- GitHub Pages (jfcaba.github.io/tren): hosts the timetable files our pipeline builds from Renfe's GTFS, plus the support and privacy pages.
- Apple Core Location, used only on the device to find the nearest station; the location is never sent anywhere.
No authentication, payment, advertising, analytics or AI services are used.

4. REGIONAL DIFFERENCES
The app works the same way in every region. Its content covers Spanish Cercanías stations only, so outside Spain the nearest-station feature has nothing nearby to show; choosing a station by hand works everywhere.

5. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
The app does not operate in a regulated industry and is non-commercial. It is an independent, unofficial app with no relationship to Renfe, and says so in its description; it uses no Renfe logos or trademarks.
All data comes from datasets Renfe publishes on its open data portal under the Creative Commons Attribution 4.0 licence (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/), which allows reuse for any purpose, with attribution:
- Timetables (GTFS): https://data.renfe.com/dataset/horarios-cercanias
- Real-time delays (GTFS-RT trip updates): https://data.renfe.com/dataset/horarios-viaje-cercanias
- Vehicle positions (live platform): https://data.renfe.com/dataset/ubicacion-vehiculos
Portal reuse terms: https://data.renfe.com/legal
As the licence requires, the app credits the source on its main screen ("Datos: Renfe"), as do its support and privacy pages.

## 1.1.0 (build 12)

Paste into App Store Connect → Andén → version 1.1.0 → App Review Information → Notes.

---

1. PURPOSE AND AUDIENCE
Andén answers one question for commuters on Spain's suburban rail network (Renfe Cercanías / Rodalies): "how long until my train?". It opens on the nearest station and lists the next departures in both directions with real-time delays and cancellations. It is for everyday passengers in Madrid, Barcelona, Valencia, Bilbao, Seville and the other Cercanías networks, who today have to dig through timetables or a general-purpose rail app to get this one answer. It is a non-commercial project: the app is free, with no ads, no in-app purchases, no analytics and no accounts.

2. HOW TO USE IT
No account or credentials are needed.
- Open the app. If location is allowed, it shows the nearest Cercanías station.
- Location is optional. If it is denied (or the reviewer is outside Spain), tap "Elegir estación" and pick any station, for example "Atocha" in the Madrid group. To change station at any time, tap the station name at the top.
- To find a station by name, tap the station name at the top and type in the search box (e.g. "Sol").
- Each train shows its platform ("vía"): live when Renfe publishes it, otherwise the usual one for that train.
- Scroll to the end of the list, or tap "Ver más", to load more trains.
- Tap a train to see its remaining stops and times.
- Tap a destination chip above the list to filter the board ("Todos" clears it); the app remembers the filter for that station.
- Between about 00:00 and 05:00 Spanish time there is no service, so the board shows the first trains of the morning.
The interface is in Spanish.

3. EXTERNAL SERVICES
- Renfe open data: the scheduled timetable (GTFS, ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip), real-time delays (GTFS-RT, gtfsrt.renfe.com/trip_updates.json) and vehicle positions, used for the live platform (gtfsrt.renfe.com/vehicle_positions.json), which the app reads directly.
- GitHub Pages (jfcaba.github.io/tren): hosts the timetable files our pipeline builds from Renfe's GTFS, plus the support and privacy pages.
- Apple Core Location, used only on the device to find the nearest station; the location is never sent anywhere.
No authentication, payment, advertising, analytics or AI services are used.

4. REGIONAL DIFFERENCES
The app works the same way in every region. Its content covers Spanish Cercanías stations only, so outside Spain the nearest-station feature has nothing nearby to show; choosing a station by hand works everywhere.

5. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
The app does not operate in a regulated industry and is non-commercial. It is an independent, unofficial app with no relationship to Renfe, and says so in its description; it uses no Renfe logos or trademarks.
All data comes from datasets Renfe publishes on its open data portal under the Creative Commons Attribution 4.0 licence (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/), which allows reuse for any purpose, with attribution:
- Timetables (GTFS): https://data.renfe.com/dataset/horarios-cercanias
- Real-time delays (GTFS-RT trip updates): https://data.renfe.com/dataset/horarios-viaje-cercanias
- Vehicle positions (live platform): https://data.renfe.com/dataset/ubicacion-vehiculos
Portal reuse terms: https://data.renfe.com/legal
As the licence requires, the app credits the source on its main screen ("Datos: Renfe"), as do its support and privacy pages.

## 1.0 (answer to Guideline 2.1, 16-11-2026)

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
- Renfe open data: the scheduled timetable (GTFS, ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip), real-time delays (GTFS-RT, gtfsrt.renfe.com/trip_updates.json), which the app reads directly.
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
