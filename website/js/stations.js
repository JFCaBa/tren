// Stations (/stations.json, website/build_pages.py): search, nearest, distance text as the app.

export function haversineMeters(lat1, lon1, lat2, lon2) {
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
}

/** The `n` closest stations in a straight line: [{station, meters}]. */
export function nearestStations(stations, lat, lon, n = 1) {
  return stations.map((station) => ({ station, meters: haversineMeters(lat, lon, station.lat, station.lon) }))
    .sort((a, b) => a.meters - b.meters).slice(0, n);
}

const norm = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/['’.·]/g, '').replace(/[-/(),&]+/g, ' ').replace(/\s+/g, ' ').trim();

/** Up to `limit` stations: name prefix, then a word prefix, then substring, then every word of the
 * query starting a word of the name in any order ("valencia nord" → València-Estació del Nord). */
export function searchStations(stations, query, limit = 8) {
  const q = norm(query ?? '');
  if (!q) return [];
  const words = q.split(' ');
  const scored = [];
  for (const s of stations) {
    const name = norm(s.name);
    let rank = null;
    if (name.startsWith(q)) rank = 1;
    else if ((' ' + name).includes(' ' + q)) rank = 2;
    else if (name.includes(q)) rank = 3;
    else if (words.length > 1 && words.every((w) => (' ' + name).includes(' ' + w))) rank = 4;
    if (rank != null) scored.push({ s, rank });
  }
  scored.sort((a, b) => a.rank - b.rank || a.s.name.localeCompare(b.s.name, 'es'));
  return scored.slice(0, limit).map((x) => x.s);
}

/** As the app (home_screen.dart): 450 m, 1,2 km. */
export const formatDistance = (m) =>
  m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1).replace('.', ',')} km`;
