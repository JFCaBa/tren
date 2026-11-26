import { test } from 'node:test';
import assert from 'node:assert/strict';
import { waitText, delayMinutes, isLate, platformText, hhmm, shortStopName, liveText } from '../js/text.js';

const dep = (o = {}) => ({ scheduled: '2026-11-15T18:10:00+01:00', estimated: '2026-11-15T18:10:00+01:00', delay: null,
  live: false, cancelled: false, minutes: 10, usualPlatform: null, livePlatform: null, ...o });

test('wait as the app: ahora, N min, h:mm h', () => {
  assert.equal(waitText(0), 'ahora');
  assert.equal(waitText(7), '7 min');
  assert.equal(waitText(75), '1:15 h');
});

test('delay minutes only when the clock time moved; late from 3 min', () => {
  assert.equal(delayMinutes(dep()), null);
  assert.equal(delayMinutes(dep({ delay: 20, estimated: '2026-11-15T18:10:20+01:00' })), null);
  assert.equal(delayMinutes(dep({ delay: 180, estimated: '2026-11-15T18:13:00+01:00' })), 3);
  assert.equal(delayMinutes(dep({ delay: -120, estimated: '2026-11-15T18:08:00+01:00' })), -2);
  assert.equal(delayMinutes(dep({ delay: 300, cancelled: true })), null);
  assert.equal(isLate(dep({ delay: 180, estimated: '2026-11-15T18:13:00+01:00' })), true);
  assert.equal(isLate(dep({ delay: 120, estimated: '2026-11-15T18:12:00+01:00' })), false);
});

test('platform: live "Vía 3", learned "vía 2 · habitual", else null', () => {
  assert.equal(platformText(dep({ livePlatform: '3', usualPlatform: '2' })), 'Vía 3');
  assert.equal(platformText(dep({ usualPlatform: '2' })), 'vía 2 · habitual');
  assert.equal(platformText(dep()), null);
});

test('clock time in Madrid whatever the browser zone', () => {
  assert.equal(hhmm('2026-11-15T18:05:00+01:00'), '18:05');
  assert.equal(hhmm('2026-11-15T17:05:00Z'), '18:05');
});

test('short names as the app', () => {
  assert.equal(shortStopName('València-Estació del Nord'), 'València Nord');
  assert.equal(shortStopName('Madrid-Atocha Cercanías'), 'Atocha');
});

test('live status: "En vivo · hh:mm" or "Sin tiempo real · horas previstas"', () => {
  assert.equal(liveText({ rtStale: false, generatedAt: '2026-11-15T17:05:09Z' }), 'En vivo · 18:05');
  assert.equal(liveText({ rtStale: true, generatedAt: '2026-11-15T17:05:09Z' }), 'Sin tiempo real · horas previstas');
});
