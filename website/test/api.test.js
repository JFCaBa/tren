import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validBoard, validStations, fetchJson, ApiError } from '../js/api.js';

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
