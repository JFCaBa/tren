import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/json_cache.dart';
import 'package:proximotren/data/positions.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/domain/board.dart';
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

  // Tests may move the clock; the positions client shares it so freshness is consistent.
  late tz.TZDateTime clockNow;
  setUp(() => clockNow = tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0));

  Future<AppController> make() async => AppController(
        server.client,
        dir,
        RealtimeClient(server.client),
        location,
        await SharedPreferences.getInstance(),
        clock: () => clockNow,
        periodic: timers.create,
        positions: PositionsClient(server.client, now: () => clockNow.toUtc()),
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

  group('live platform', () {
    // T2 leaves Silla (64200) at 19:00; the realtime fixture is stale by then, so it is on time.
    tz.TZDateTime minute(int h, int m) => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, h, m);
    Departure? t2(AppController c) => c.board!.departures.where((d) => d.tripId == 'T2').firstOrNull;

    test('does not fetch positions when no train within 5 min', () async {
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      expect(c.board, isNotNull);
      expect(server.positionsCalls, 0);
    });

    test('fetches positions and shows live platform when a train is near', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      expect(t2(c)!.minutes, lessThanOrEqualTo(5));
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, greaterThan(0));
      expect(t2(c)!.livePlatform, '2');
    });

    test('positions are fetched at most once a minute', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      final first = server.positionsCalls;
      expect(first, greaterThan(0));
      clockNow = clockNow.add(const Duration(seconds: 30));
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, first);
      clockNow = clockNow.add(const Duration(seconds: 30));
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, first + 1);
    });

    test('a clock moved backwards does not block positions', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      final first = server.positionsCalls;
      clockNow = minute(18, 55);
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, first + 1);
    });

    test('a platform reported at another station is not shown', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '65000', '7', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      expect(t2(c)!.livePlatform, isNull);
    });

    test('positions failure keeps the last live platform', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      server.positionsFails = true;
      clockNow = minute(18, 57);
      final before = server.positionsCalls;
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, before + 1);
      expect(t2(c)!.livePlatform, '2');
      clockNow = minute(18, 59);
      timers.timers.last.fire();
      await settle();
      expect(t2(c)!.livePlatform, '2', reason: 'a platform once seen stays until the train leaves');
    });

    test('a platform Renfe stops reporting is remembered, also after a restart', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      expect(t2(c)!.livePlatform, '2');
      // Renfe drops the label while the train stands at the platform.
      clockNow = minute(18, 58);
      server.positionsBody = jsonEncode({
        'header': {'timestamp': '${clockNow.millisecondsSinceEpoch ~/ 1000}'},
        'entity': [],
      });
      timers.timers.last.fire();
      await settle();
      expect(t2(c)!.livePlatform, '2');
      c.dispose();
      // The app is closed and opened again.
      final again = await startedAt(nearSilla);
      expect(t2(again)!.livePlatform, '2');
    });

    test('a newer sighting replaces the remembered platform', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      clockNow = minute(18, 57);
      server.positionsBody = positionsJson('T2', '64200', '4', clockNow);
      timers.timers.last.fire();
      await settle();
      expect(t2(c)!.livePlatform, '4');
    });

    test('a remembered platform is forgotten after 20 minutes', () async {
      Future<Departure?> t2SeenAt(tz.TZDateTime seen) async {
        SharedPreferences.setMockInitialValues({
          'seen_platforms': jsonEncode({'64200|T2': ['2', seen.toUtc().toIso8601String()]}),
        });
        server.positionsFails = true;
        clockNow = minute(18, 56);
        return t2(await startedAt(nearSilla));
      }

      expect((await t2SeenAt(minute(18, 40)))!.livePlatform, '2');
      final old = await t2SeenAt(minute(18, 35));
      expect(old, isNotNull, reason: 'the train is still on the board');
      expect(old!.livePlatform, isNull);
    });

    test('seeing the same platform again renews when it was seen', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      clockNow = minute(18, 57);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      timers.timers.last.fire();
      await settle();
      expect(c.board, isNotNull);
      final saved = jsonDecode((await SharedPreferences.getInstance()).getString('seen_platforms')!) as Map;
      expect(saved['64200|T2'], ['2', clockNow.toUtc().toIso8601String()]);
    });

    test('older positions response is ignored', () async {
      clockNow = minute(18, 56);
      server.positionsBody = positionsJson('T2', '64200', '2', clockNow);
      final c = await startedAt(nearSilla);
      timers.timers.last.fire();
      await settle();
      server.positionsBody = positionsJson('T2', '64200', '5', clockNow.subtract(const Duration(seconds: 30)));
      clockNow = minute(18, 57);
      final before = server.positionsCalls;
      timers.timers.last.fire();
      await settle();
      expect(server.positionsCalls, before + 1);
      expect(t2(c)!.livePlatform, '2');
    });
  });

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

  test('recent stations: newest first, current one left out, persisted', () async {
    final c = await startedAt(nearSilla);
    expect(c.recentStations, isEmpty);
    c.selectStation('69110');
    expect(c.recentStations.map((s) => s.id), ['64200']);
    c.selectStation('18000');
    expect(c.recentStations.map((s) => s.id), ['69110', '64200']);
    c.selectStation('64200');
    expect(c.recentStations.map((s) => s.id), ['18000', '69110']);
    expect((await SharedPreferences.getInstance()).getString('recent_stations'), '["64200","18000","69110"]');
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

  test('provisional saved station uses cache only until GPS answers', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    await warmCache();
    server.requested.clear();
    final c = await make();
    final started = c.start();
    await settle();
    expect(c.station!.id, '64200');
    expect(c.feeds.map((f) => f.nucleo), ['40']); // from cache
    expect(server.requested, isNot(contains('feeds/40.json')));
    location.answer(nearAtocha);
    await started;
    expect(server.requested, contains('feeds/10.json'));
    expect(server.requested, isNot(contains('feeds/40.json')));
  });

  test('saved station is refreshed once GPS confirms it', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    await warmCache();
    server.requested.clear();
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(server.requested, contains('feeds/40.json'));
  });

  test('saved station is refreshed when location is denied', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    await warmCache();
    server.requested.clear();
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(null);
    await started;
    expect(server.requested, contains('feeds/40.json'));
  });

  test('pause during start does not leave the saved station provisional', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    await warmCache();
    server.requested.clear();
    final c = await make();
    final started = c.start();
    await settle();
    c.onPause(); // invalidates the pending GPS answer
    final resumed = c.onResume();
    await settle();
    location.answer(nearSilla);
    await settle();
    location.answer(nearSilla);
    await Future.wait([started, resumed]);
    await settle();
    expect(server.requested, contains('feeds/40.json'));
  });

  test('concurrent retries run once', () async {
    final c = await startedAt(nearSilla);
    server.requested.clear();
    server.hold('index.json');
    final a = c.retry(), b = c.retry();
    await settle();
    server.release('index.json');
    location.answer(nearSilla);
    await Future.wait([a, b]);
    expect(server.requested.where((p) => p == 'index.json').length, 1);
  });

  test('retrying flag while retry runs', () async {
    server.feedFails = true;
    final c = await startedAt(nearSilla);
    expect(c.retrying, isFalse);
    server.feedFails = false;
    server.hold('index.json');
    final r = c.retry();
    await settle();
    expect(c.retrying, isTrue);
    server.release('index.json');
    location.answer(nearSilla);
    await r;
    expect(c.retrying, isFalse);
  });

  test('loadMore adds a page while the schedule has more, filters reset it', () async {
    server.feed40Override = manyTrainsFeed(20);
    final c = await startedAt(nearSilla);
    expect(c.board!.departures, hasLength(8));
    c.loadMore();
    expect(c.board!.departures, hasLength(16));
    c.loadMore();
    expect(c.board!.departures, hasLength(20));
    expect(c.board!.hasMore, isFalse);
    c.loadMore();
    expect(c.limit, 24); // no growth once everything is shown
    c.toggleFilter('Gandia');
    expect(c.limit, 8);
    expect(c.board!.departures, hasLength(8));
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

  group('via (Otra parada)', () {
    test('setVia filters to trains that reach it, clears destinations and persists per station', () async {
      final c = await startedAt(nearSilla);
      c.toggleFilter('València-Estació del Nord');
      c.setVia('69110');
      expect(c.filters, isEmpty);
      expect(c.via, '69110');
      expect(c.viaName, 'Gandia');
      expect(c.board!.departures.map((d) => d.tripId), ['T1']);
      expect(c.board!.departures.single.arrival!.name, 'Gandia');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('via_64200'), '69110');
      expect(prefs.getString('filters_64200'), '[]');
      final c2 = await startedAt(nearSilla);
      expect(c2.via, '69110');
    });

    test('the widget board keeps the stop chosen and has more trains than the list', () async {
      final c = await startedAt(nearSilla);
      expect(c.widgetBoard!.departures.length, greaterThanOrEqualTo(c.board!.departures.length));
      c.setVia('69110');
      expect(c.widgetBoard!.departures.map((d) => d.tripId), ['T1']);
      c.clearFilters();
      expect(c.widgetBoard!.departures.length, greaterThan(1));
    });

    test('a destination chip or Todos clears via', () async {
      final c = await startedAt(nearSilla);
      c.setVia('69110');
      c.toggleFilter('Gandia');
      expect(c.via, isNull);
      expect((await SharedPreferences.getInstance()).getString('via_64200'), isNull);
      c.setVia('69110');
      c.clearFilters();
      expect(c.via, isNull);
    });

    test('a saved via the schedule no longer reaches is forgotten', () async {
      SharedPreferences.setMockInitialValues({'via_64200': '99999'});
      final c = await startedAt(nearSilla);
      expect(c.via, isNull);
      expect((await SharedPreferences.getInstance()).getString('via_64200'), isNull);
    });

    test('a saved via with no train today is kept', () async {
      SharedPreferences.setMockInitialValues({'via_64200': '69110'});
      clockNow = tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 16, 18, 0); // T1 only runs on the 15th
      final c = await startedAt(nearSilla);
      expect(c.via, '69110');
      expect(c.board!.departures, isEmpty);
    });
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
