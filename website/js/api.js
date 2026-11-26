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

/** A first board without real time (the server was idle and is waking its Renfe reader) is asked
 * again after 5 s rather than at the next 30 s refresh; only once per page. */
export const retryAfterMs = (previous, board) => (previous == null && board.rtStale ? 5000 : null);

/** One signal that aborts when the caller's does or after `ms`. Built by hand: AbortSignal.any
 * (Safari 17.4+) and AbortSignal.timeout (Safari 16+) are missing on iPhones that cannot update. */
function deadline(signal, ms) {
  const c = new AbortController();
  const timer = setTimeout(() => c.abort(new DOMException('timeout', 'TimeoutError')), ms);
  const onAbort = () => c.abort(signal.reason);
  if (signal?.aborted) onAbort();
  else signal?.addEventListener('abort', onAbort, { once: true });
  return { signal: c.signal, timedOut: () => c.signal.aborted && !signal?.aborted,
    done: () => { clearTimeout(timer); signal?.removeEventListener('abort', onAbort); } };
}

/** GET `url` as JSON, giving up after `timeoutMs` (then 'network'). Throws ApiError, or the
 * AbortError of a request the caller aborted through `signal`. */
export async function fetchJson(url, fetchImpl = fetch, signal, timeoutMs = 15_000) {
  const d = deadline(signal, timeoutMs);
  let r;
  try {
    r = await fetchImpl(url, { signal: d.signal });
  } catch (e) {
    d.done();
    if (signal?.aborted) throw new DOMException('aborted', 'AbortError'); // the caller moved on
    if (e?.name === 'AbortError' && !d.timedOut()) throw e;
    throw new ApiError('network'); // offline, refused, or timed out
  }
  try {
    if (r.status === 404) throw new ApiError('notfound', 404);
    if (r.status === 429) throw new ApiError('ratelimited', 429);
    if (!r.ok) throw new ApiError('unavailable', r.status);
    try {
      return JSON.parse(await r.text());
    } catch {
      throw new ApiError('unavailable', r.status);
    }
  } finally {
    d.done();
  }
}
