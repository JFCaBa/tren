import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/json_cache.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

void main() {
  late Directory dir;
  late FakeServer server;
  late FakeLocation location;
  late TimerLog timers;

  setUpAll(tzdata.initializeTimeZones);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ctrl');
    server = FakeServer();
    location = FakeLocation();
    timers = TimerLog();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppController> make() async => AppController(
        server.client,
        dir,
        RealtimeClient(server.client),
        location,
        await SharedPreferences.getInstance(),
        clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
        periodic: timers.create,
      );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  Future<AppController> startedAt((double, double) where) async {
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(where);
    await started;
    return c;
  }

  Future<void> warmCache() async {
    await indexCache(server.client, dir).refresh();
    await nucleoCache(server.client, dir, '40').refresh();
  }

  test('picks nearest station from location and loads its nucleo', () async {
    final c = await startedAt(nearSilla);
    expect(c.station!.id, '64200');
    expect(c.distanceMeters, lessThan(200));
    expect(c.feeds.map((f) => f.nucleo), ['40']);
    expect(c.board, isNotNull);
    expect(c.needsStationPick, isFalse);
  });

  test('moving to another nucleo loads its feed', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    await warmCache();
    final c = await startedAt(nearAtocha);
    expect(c.station!.id, '18000');
    expect(c.feeds.map((f) => f.nucleo), ['10']);
    expect(c.board!.departures.every((d) => d.tripId.startsWith('M')), isTrue);
  });

  test('shared station loads both nucleos', () async {
    final c = await startedAt(nearShared);
    expect(c.station!.id, 'X1');
    expect(c.feeds.map((f) => f.nucleo).toSet(), {'10', '40'});
    expect(c.board!.departures.map((d) => d.tripId).toSet(), {'TX', 'MX'});
  });

  test('shared station with one nucleo offline shows incomplete', () async {
    server.failing.add('feeds/10.json');
    final c = await startedAt(nearShared);
    expect(c.board!.missingNucleos, ['10']);
    expect(c.board!.departures.map((d) => d.tripId), ['TX']);
  });

  test('test_location_denied_uses_saved_station', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    final c = await startedAt(nearSilla);
    expect(c.station!.id, '64200');
    final c2 = await make();
    location.immediate = null;
    final s2 = c2.start();
    await settle();
    location.answer(null);
    await s2;
    expect(c2.station!.id, '64200');
    expect(c2.needsStationPick, isFalse);
  });

  test('location denied without saved station asks to pick', () async {
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(null);
    await started;
    expect(c.station, isNull);
    expect(c.needsStationPick, isTrue);
  });

  test('manual station survives resume', () async {
    final c = await startedAt(nearSilla);
    c.selectStation('69110');
    c.onPause();
    final resumed = c.onResume();
    await settle();
    location.answer(nearSilla);
    await resumed;
    expect(c.station!.id, '69110');
    expect(c.manualStation, isTrue);
    expect((await SharedPreferences.getInstance()).getString('last_station'), '69110');
  });

  test('late location does not override manual pick', () async {
    final c = await make();
    final started = c.start();
    await settle();
    c.selectStation('69110');
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '69110');
  });

  test('late nucleo load for previous station is ignored', () async {
    server.hold('feeds/40.json');
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla); // starts loading 40 (held)
    await settle();
    c.selectStation('18000'); // Madrid
    await settle();
    server.release('feeds/40.json');
    await started;
    await settle();
    expect(c.station!.id, '18000');
    expect(c.feeds.map((f) => f.nucleo), ['10']);
  });

  test('station nucleos changed by a new index reload its feeds', () async {
    final c = await startedAt(nearSilla);
    expect(c.feeds.map((f) => f.nucleo), ['40']);
    server.indexOverride = fixture('index.json').replaceFirst(
        '"id":"64200","name":"Silla","lat":39.3619548,"lon":-0.4149813,"nucleos":["40"]',
        '"id":"64200","name":"Silla","lat":39.3619548,"lon":-0.4149813,"nucleos":["40","10"]');
    final r = c.retry();
    await settle();
    location.answer(nearSilla);
    await r;
    await settle();
    expect(c.feeds.map((f) => f.nucleo).toSet(), {'40', '10'});
  });

  test('filters persist per station', () async {
    final c = await startedAt(nearSilla);
    c.toggleFilter('Gandia');
    expect(c.filters, {'Gandia'});
    expect(c.board!.departures.every((d) => d.dest == 'Gandia'), isTrue);
    final c2 = await startedAt(nearSilla);
    expect(c2.filters, {'Gandia'});
    c2.clearFilters();
    expect(c2.filters, isEmpty);
  });

  test('stale filter falls back to all', () async {
    SharedPreferences.setMockInitialValues({'filters_64200': '["Atlántida"]'});
    final c = await startedAt(nearSilla);
    expect(c.filters, isEmpty);
    expect((await SharedPreferences.getInstance()).getString('filters_64200'), '[]');
  });

  test('saved filters survive while feeds load', () async {
    SharedPreferences.setMockInitialValues({'filters_64200': '["Gandia"]'});
    server.hold('feeds/40.json');
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await settle();
    expect(c.filters, {'Gandia'});
    server.release('feeds/40.json');
    await started;
    expect(c.filters, {'Gandia'});
  });

  test('rt failure keeps board with rtStale', () async {
    server.rtFails = true;
    final c = await startedAt(nearSilla);
    expect(c.board, isNotNull);
    expect(c.board!.rtStale, isTrue);
    expect(c.error, isNull);
  });

  test('single timer after repeated resume', () async {
    final c = await startedAt(nearSilla);
    for (var i = 0; i < 3; i++) {
      final r = c.onResume();
      await settle();
      location.answer(nearSilla);
      await r;
    }
    expect(timers.active, 1);
    c.onPause();
    expect(timers.active, 0);
    c.dispose();
  });

  test('timer tick polls realtime', () async {
    await startedAt(nearSilla);
    final before = server.rtCalls;
    timers.timers.last.fire();
    await settle();
    expect(server.rtCalls, before + 1);
  });

  test('location before index resolves station when index arrives', () async {
    location.immediate = nearGandia;
    final c = await make();
    await c.start();
    expect(c.station!.id, '69110');
  });

  test('cached index without saved station does not ask to pick while locating', () async {
    await warmCache();
    final c = await make();
    final started = c.start();
    await settle();
    expect(c.needsStationPick, isFalse);
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '64200');
  });

  test('start uses last_station while location pending', () async {
    await warmCache();
    SharedPreferences.setMockInitialValues({'last_station': '69110'});
    final c = await make();
    final started = c.start();
    await settle();
    expect(c.station!.id, '69110');
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '64200');
  });

  test('dispose during start leaves no timer', () async {
    final c = await make();
    final started = c.start();
    c.dispose();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(timers.active, 0);
  });

  test('pause during start leaves no timer', () async {
    final c = await make();
    final started = c.start();
    c.onPause();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(timers.active, 0);
  });

  test('resume during start does not duplicate work', () async {
    final c = await make();
    final started = c.start();
    final resumed = c.onResume();
    await settle();
    location.answer(nearSilla);
    await Future.wait([started, resumed]);
    expect(server.rtCalls, 1);
    expect(location.requests.length, 1);
  });

  test('start and retry may ask for permission, resume does not', () async {
    final c = await startedAt(nearSilla);
    final resumed = c.onResume();
    await settle();
    location.answer(nearSilla);
    await resumed;
    final retried = c.retry();
    await settle();
    location.answer(nearSilla);
    await retried;
    expect(location.requests, [true, false, true]);
  });

  test('useLocation returns to automatic station', () async {
    final c = await startedAt(nearSilla);
    c.selectStation('69110');
    final back = c.useLocation();
    await settle();
    location.answer(nearSilla);
    await back;
    expect(c.manualStation, isFalse);
    expect(c.station!.id, '64200');
  });

  test('first launch offline without index reports error', () async {
    server.feedFails = true;
    final c = await startedAt(nearSilla);
    expect(c.index, isNull);
    expect(c.error, isNotNull);
    server.feedFails = false;
    final retried = c.retry();
    await settle();
    location.answer(nearSilla);
    await retried;
    expect(c.error, isNull);
    expect(c.station!.id, '64200');
    expect(c.board, isNotNull);
  });
}
