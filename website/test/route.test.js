import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseRoute, extraBelongs } from '../js/route.js';

test('home, station with or without trailing slash, anything else not found', () => {
  assert.deepEqual(parseRoute('/'), { page: 'home' });
  assert.deepEqual(parseRoute('/estacion/65000'), { page: 'station', id: '65000', canonical: '/estacion/65000' });
  assert.deepEqual(parseRoute('/estacion/04040/'), { page: 'station', id: '04040', canonical: '/estacion/04040' });
  for (const p of ['/estacion/6500', '/estacion/650000', '/estacion/abcde', '/station/KGX', '/foo', '/estacion/']) {
    assert.equal(parseRoute(p).page, 'notfound', p);
  }
});

test('extraBelongs: the server-built aside only on its own page', () => {
  assert.equal(extraBelongs('/estacion/65000', '/estacion/65000'), true);
  assert.equal(extraBelongs('/estacion/65000', '/estacion/65000/'), true);
  assert.equal(extraBelongs('/estacion/65000', '/estacion/64200'), false);
  assert.equal(extraBelongs('/', '/'), true);
  assert.equal(extraBelongs('/', '/estacion/65000'), false);
  assert.equal(extraBelongs(undefined, '/'), false);
});
