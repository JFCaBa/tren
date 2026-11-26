import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validBoard, validStations, fetchJson, ApiError, retryAfterMs } from '../js/api.js';

const board = () => ({ generatedAt: '2026-11-15T17:00:00Z', station: { id: '65000', name: 'València Nord', nucleos: ['Valencia'] },
  rtStale: false, feedStale: false, feedCoversToday: true, hasMore: false,
  departures: [{ tripId: 'a', line: 'C1', color: '#7AB3DE', dest: 'Gandia', scheduled: '2026-11-15T18:10:00+01:00',
    estimated: '2026-11-15T18:10:00+01:00', delay: null, live: false, cancelled: false, minutes: 10,
    usualPlatform: null, livePlatform: null, stops: [{ id: '65000', name: 'València Nord', time: '2026-11-15T18:10:00+01:00' }] }] });

test('validBoard accepts the API shape and rejects anything else', () => {
  assert.equal(validBoard(board()), true);
  for (const bad of [null, {}, { ...board(), departures: null }, { ...board(), generatedAt: 'x' },
    { ...board(), station: null }, { ...board(), departures: [{ ...board().departures[0], estimated: 'nope' }] },
    { ...board(), departures: [{ ...board().departures[0], color: 'red;}' }] }]) {
    assert.equal(validBoard(bad), false, JSON.stringify(bad));
  }
});

test('validStations', () => {
  assert.equal(validStations([{ id: '65000', name: 'N', lat: 1, lon: 2, nucleo: 'V' }]), true);
  assert.equal(validStations([{ id: '65000', name: 'N', lat: 'x', lon: 2 }]), false);
  assert.equal(validStations({}), false);
});

test('fetchJson maps statuses to ApiError kinds', async () => {
  const resp = (status, body = '{}') => async () => ({ status, ok: status < 400, text: async () => body });
  await assert.rejects(fetchJson('/x', resp(404)), (e) => e instanceof ApiError && e.kind === 'notfound');
  await assert.rejects(fetchJson('/x', resp(429)), (e) => e.kind === 'ratelimited');
  await assert.rejects(fetchJson('/x', resp(503)), (e) => e.kind === 'unavailable');
  await assert.rejects(fetchJson('/x', async () => { throw new TypeError('offline'); }), (e) => e.kind === 'network');
  assert.deepEqual(await fetchJson('/x', resp(200, '{"a":1}')), { a: 1 });
});

test('fetchJson works without AbortSignal.any and AbortSignal.timeout (Safari < 17.4)', async () => {
  const { any, timeout } = AbortSignal;
  delete AbortSignal.any;
  delete AbortSignal.timeout;
  try {
    const ok = async () => ({ status: 200, ok: true, text: async () => '{"a":1}' });
    assert.deepEqual(await fetchJson('/x', ok, new AbortController().signal), { a: 1 });
    const caller = new AbortController();
    const hang = (_url, { signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new DOMException('a', 'AbortError'))));
    const p = fetchJson('/x', hang, caller.signal);
    caller.abort();
    await assert.rejects(p, (e) => e.name === 'AbortError');
    await assert.rejects(fetchJson('/x', hang, undefined, 20), (e) => e instanceof ApiError && e.kind === 'network');
  } finally {
    AbortSignal.any = any;
    AbortSignal.timeout = timeout;
  }
});

test('retryAfterMs: a first board without real time is asked again soon', () => {
  const b = (rtStale) => ({ rtStale });
  assert.equal(retryAfterMs(null, b(true)), 5000);
  assert.equal(retryAfterMs(null, b(false)), null);
  assert.equal(retryAfterMs(b(true), b(true)), null); // only once per page
});
