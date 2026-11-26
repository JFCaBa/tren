import { test } from 'node:test';
import assert from 'node:assert/strict';
import { searchStations, nearestStations, formatDistance } from '../js/stations.js';

const ST = [
  { id: '65000', name: 'València-Estació del Nord', lat: 39.4669, lon: -0.3772, nucleo: 'Valencia' },
  { id: '18000', name: 'Madrid-Atocha Cercanías', lat: 40.4066, lon: -3.6903, nucleo: 'Madrid' },
  { id: '18101', name: 'Sol', lat: 40.4169, lon: -3.7035, nucleo: 'Madrid' },
  { id: '05665', name: 'Solares', lat: 43.38, lon: -3.73, nucleo: 'Santander' },
  { id: '64200', name: 'Silla', lat: 39.362, lon: -0.415, nucleo: 'Valencia' },
  { id: '79600', name: "Sant Adrià de Besòs", lat: 41.425, lon: 2.216, nucleo: 'Rodalies de Catalunya' },
];

test('search ignores accents, case and dashes; name prefix before word prefix before substring', () => {
  assert.equal(searchStations(ST, 'valencia nord')[0].id, '65000');
  assert.equal(searchStations(ST, 'atocha')[0].id, '18000');
  assert.deepEqual(searchStations(ST, 'sol').map((s) => s.id), ['18101', '05665']);
  assert.equal(searchStations(ST, 'adria')[0].id, '79600');
  assert.equal(searchStations(ST, 'SILLA')[0].id, '64200');
  assert.deepEqual(searchStations(ST, '   '), []);
  assert.equal(searchStations(ST, 's', 2).length, 2);
});

test('nearest stations by distance, with meters', () => {
  const n = nearestStations(ST, 39.47, -0.376, 2);
  assert.deepEqual(n.map((x) => x.station.id), ['65000', '64200']);
  assert.ok(n[0].meters < 500);
  assert.deepEqual(nearestStations([], 0, 0, 3), []);
});

test('distance as the app: 450 m, 1,2 km', () => {
  assert.equal(formatDistance(447), '450 m');
  assert.equal(formatDistance(1234), '1,2 km');
});
