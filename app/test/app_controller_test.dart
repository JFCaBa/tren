import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/feed_repository.dart';
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
        FeedRepository(server.client, dir),
        RealtimeClient(server.client),
        location,
        await SharedPreferences.getInstance(),
        clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
        periodic: timers.create,
      );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('picks nearest station from location', () async {
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '64200');
    expect(c.distanceMeters, lessThan(200));
    expect(c.board, isNotNull);
    expect(c.needsStationPick, isFalse);
  });

  test('test_location_denied_uses_saved_station', () async {
    SharedPreferences.setMockInitialValues({'last_station': '64200'});
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(null);
    await started;
    expect(c.station!.id, '64200');
    expect(c.needsStationPick, isFalse);
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
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
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

  test('rt failure keeps board with rtStale', () async {
    server.rtFails = true;
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(c.board, isNotNull);
    expect(c.board!.rtStale, isTrue);
    expect(c.error, isNull);
  });

  test('single timer after repeated resume', () async {
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
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
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    final before = server.rtCalls;
    timers.timers.last.fire();
    await settle();
    expect(server.rtCalls, before + 1);
  });

  test('location before feed resolves station when feed arrives', () async {
    location.immediate = nearGandia; // answers before the download finishes
    final c = await make(); // empty cache: feed must be downloaded
    await c.start();
    expect(c.station!.id, '69110');
  });

  test('start uses last_station while location pending', () async {
    await FeedRepository(server.client, dir).refresh(); // warm cache
    SharedPreferences.setMockInitialValues({'last_station': '69110'});
    final c = await make();
    final started = c.start();
    await settle();
    expect(c.station!.id, '69110');
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '64200');
  });

  test('cached feed without saved station does not ask to pick while locating', () async {
    await FeedRepository(server.client, dir).refresh(); // warm cache, no last_station
    final c = await make();
    final started = c.start();
    await settle();
    expect(c.needsStationPick, isFalse);
    location.answer(nearSilla);
    await started;
    expect(c.station!.id, '64200');
  });

  test('dispose during start leaves no timer', () async {
    final c = await make();
    final started = c.start();
    c.dispose();
    location.answer(nearSilla);
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
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
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
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    c.selectStation('69110');
    final back = c.useLocation();
    await settle();
    location.answer(nearSilla);
    await back;
    expect(c.manualStation, isFalse);
    expect(c.station!.id, '64200');
  });

  test('test_first_launch_offline_reports_error', () async {
    server.feedFails = true;
    final c = await make();
    final started = c.start();
    await settle();
    location.answer(nearSilla);
    await started;
    expect(c.feed, isNull);
    expect(c.error, isNotNull);
    server.feedFails = false;
    final retried = c.retry();
    await settle();
    location.answer(nearSilla);
    await retried;
    expect(c.error, isNull);
    expect(c.station!.id, '64200');
  });
}
