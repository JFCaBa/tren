// Texts of a departure, as the app (app/lib/ui/departure_row.dart, names.dart, home_screen.dart).

const LATE_MINUTES = 3;
const madrid = new Intl.DateTimeFormat('es-ES', { timeZone: 'Europe/Madrid', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

/** "18:05", Renfe's civil time (Europe/Madrid) whatever the browser's zone. */
export const hhmm = (iso) => madrid.format(new Date(iso));

/** "ahora", "N min" under an hour, "h:mm h" from an hour on. */
export function waitText(minutes) {
  if (minutes <= 0) return 'ahora';
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')} h`;
}

/** Whole minutes of delay, only when the clock time moved; null otherwise. */
export function delayMinutes(d) {
  if (d.delay == null || d.cancelled || hhmm(d.scheduled) === hhmm(d.estimated)) return null;
  const m = Math.round(d.delay / 60);
  return m === 0 ? null : m;
}

export const isLate = (d) => (delayMinutes(d) ?? 0) >= LATE_MINUTES;

/** "Vía 3" when Renfe reports it live, "vía 2 · habitual" when only learned, else null. */
export function platformText(d) {
  if (d.livePlatform != null) return `Vía ${d.livePlatform}`;
  if (d.usualPlatform != null) return `vía ${d.usualPlatform} · habitual`;
  return null;
}

const SHORT = { 'València-Estació del Nord': 'València Nord', 'Madrid-Chamartín-Clara Campoamor': 'Chamartín' };

export function shortStopName(name) {
  if (SHORT[name]) return SHORT[name];
  let n = name;
  if (n.startsWith('Madrid-')) n = n.slice('Madrid-'.length);
  if (n.endsWith(' Cercanías')) n = n.slice(0, -' Cercanías'.length);
  return n;
}

/** "En vivo · 18:05" or "Sin tiempo real · horas previstas". */
export const liveText = (b) => (b.rtStale ? 'Sin tiempo real · horas previstas' : `En vivo · ${hhmm(b.generatedAt)}`);
