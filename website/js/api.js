// The Andén board API, same origin: andenapp.com proxies /api/board/<id> to the Andén API
// (server/anden_api, GET /board/<stop>); website/dev.py does the same locally.

export class ApiError extends Error {
  /** @param {'notfound'|'ratelimited'|'unavailable'|'network'} kind */
  constructor(kind, status = 0) {
    super(`api ${kind}${status ? ` (${status})` : ''}`);
    this.kind = kind;
    this.status = status;
  }
}

const isStr = (v) => typeof v === 'string';
const isDate = (v) => isStr(v) && !Number.isNaN(Date.parse(v));
const isOptStr = (v) => v == null || isStr(v);

const validDeparture = (d) => d != null && isStr(d.tripId) && isStr(d.line) && isStr(d.dest)
  && isStr(d.color) && /^#[0-9A-Fa-f]{6}$/.test(d.color) && isDate(d.scheduled) && isDate(d.estimated)
  && Number.isInteger(d.minutes) && (d.delay == null || Number.isInteger(d.delay))
  && typeof d.live === 'boolean' && typeof d.cancelled === 'boolean'
  && isOptStr(d.usualPlatform) && isOptStr(d.livePlatform)
  && Array.isArray(d.stops) && d.stops.every((s) => s && isStr(s.id) && isStr(s.name) && isDate(s.time));

/** A board the page can draw: anything else is treated as the API being unavailable. */
export const validBoard = (j) => j != null && typeof j === 'object' && isDate(j.generatedAt)
  && j.station != null && isStr(j.station.id) && isStr(j.station.name) && Array.isArray(j.station.nucleos)
  && typeof j.rtStale === 'boolean' && Array.isArray(j.departures) && j.departures.every(validDeparture);

/** The station list: [{id, name, lat, lon, nucleo}]. */
export const validStations = (j) => Array.isArray(j)
  && j.every((x) => x && isStr(x.id) && isStr(x.name) && Number.isFinite(x.lat) && Number.isFinite(x.lon));

/** GET `url` as JSON, giving up after `timeoutMs` (then 'network'). Throws ApiError, or the
 * AbortError of a request the caller aborted through `signal`. */
export async function fetchJson(url, fetchImpl = fetch, signal, timeoutMs = 15_000) {
  const timeout = AbortSignal.timeout(timeoutMs);
  let r;
  try {
    r = await fetchImpl(url, { signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
  } catch (e) {
    if (signal?.aborted) throw new DOMException('aborted', 'AbortError'); // the caller moved on
    if (e?.name === 'AbortError' && !timeout.aborted) throw e;
    throw new ApiError('network'); // offline, refused, or timed out
  }
  if (r.status === 404) throw new ApiError('notfound', 404);
  if (r.status === 429) throw new ApiError('ratelimited', 429);
  if (!r.ok) throw new ApiError('unavailable', r.status);
  try {
    return JSON.parse(await r.text());
  } catch {
    throw new ApiError('unavailable', r.status);
  }
}
