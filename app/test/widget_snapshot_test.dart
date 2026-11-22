import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/domain/board.dart';
import 'package:proximotren/widget/next_trains_widget.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  tzdata.initializeTimeZones();
  tz.TZDateTime t(int h, int m) => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, h, m);
  final now = t(18, 0);

  Departure dep(String id, int m,
          {int? delaySec, String? live, String? usual, bool canceled = false, StopTime? arrival, bool byId = true}) =>
      Departure(
        tripId: id,
        line: 'C1',
        dest: 'València-Estació del Nord',
        scheduled: t(18, m),
        estimated: t(18, m).add(Duration(seconds: delaySec ?? 0)),
        delaySec: delaySec,
        live: delaySec != null,
        canceled: canceled,
        minutes: m,
        color: 0xFF7AB3DE,
        livePlatform: live,
        usualPlatform: usual,
        arrival: arrival,
        realtimeById: byId,
      );

  Board board(List<Departure> ds) => Board(
      departures: ds, destinations: const [], missingNucleos: const [], rtStale: false, feedStale: false, feedCoversToday: true);

  test('fields of each train; live platform wins over the usual one', () {
    final s = widgetSnapshot(
        'Silla', board([dep('A', 5, delaySec: 240, live: '2', usual: '1'), dep('B', 9, usual: '3', byId: false)]), now);
    expect(s['station'], 'Silla');
    expect(s['via'], isNull);
    final trains = s['trains'] as List;
    expect(trains[0], {
      'line': 'C1',
      'color': 0xFF7AB3DE,
      'dest': 'València Nord',
      'sched': t(18, 5).millisecondsSinceEpoch ~/ 1000,
      'arrSched': null,
      'delaySec': 240,
      'canceled': false,
      'platform': '2',
      'live': true,
      'rt': 'A',
    });
    expect((trains[1] as Map)['platform'], '3');
    expect((trains[1] as Map)['live'], false);
    expect((trains[1] as Map)['delaySec'], isNull);
    expect((trains[1] as Map)['rt'], isNull, reason: 'a trip id that runs on several days gets no real time');
  });

  test('at most 60, none that already left, scheduled arrival with a chosen stop', () {
    final many = [for (var i = 0; i < 70; i++) dep('T$i', 1 + i ~/ 2)];
    final s = widgetSnapshot('Silla', board([dep('gone', 0).copyLeft(now), ...many]), t(18, 1));
    final trains = s['trains'] as List;
    expect(trains, hasLength(widgetTrains));
    expect((trains.first as Map)['sched'], t(18, 1).millisecondsSinceEpoch ~/ 1000);
    // Arrival given with the delay applied; the widget gets it without, and adds the delay it trusts.
    final arr = StopTime(stopId: '69110', name: 'Gandia', time: t(18, 53));
    final v = widgetSnapshot('Silla', board([dep('A', 5, delaySec: 180, arrival: arr)]), now, via: 'Gandia');
    expect(v['via'], 'Gandia');
    expect(((v['trains'] as List).single as Map)['arrSched'], t(18, 50).millisecondsSinceEpoch ~/ 1000);
  });

  test('publisher writes only changes, never a missing or empty board', () async {
    final writes = <String>[];
    final p = WidgetPublisher(write: (j) async => writes.add(j));
    await p.publish(null, board([dep('A', 5)]), now);
    await p.publish('Silla', null, now);
    await p.publish('Silla', board(const []), now);
    expect(writes, isEmpty);
    await p.publish('Silla', board([dep('A', 5)]), now);
    await p.publish('Silla', board([dep('A', 5)]), now.add(const Duration(seconds: 30)));
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single)['updatedAt'], now.millisecondsSinceEpoch ~/ 1000);
    expect(jsonDecode(writes.single)['rtAt'], isNull, reason: 'no real time used');
    await p.publish('Silla', board([dep('A', 5, delaySec: 120)]), now);
    expect(writes, hasLength(2));
    // Unchanged, but written again after a while so the widget keeps trusting the app's delays.
    await p.publish('Silla', board([dep('A', 5, delaySec: 120)]), now.add(widgetRewriteEvery));
    expect(writes, hasLength(3));
  });

  test('rtAt is the time of the real time used, and only when the board had it fresh', () async {
    final writes = <String>[];
    final p = WidgetPublisher(write: (j) async => writes.add(j));
    final at = now.subtract(const Duration(seconds: 40));
    await p.publish('Silla', board([dep('A', 5)]), now, rtAt: at);
    expect(jsonDecode(writes.last)['rtAt'], at.millisecondsSinceEpoch ~/ 1000);
    final offline = Board(
        departures: [dep('A', 5, delaySec: 60)],
        destinations: const [],
        missingNucleos: const [],
        rtStale: true,
        feedStale: false,
        feedCoversToday: true);
    await p.publish('Silla', offline, now, rtAt: at);
    expect(jsonDecode(writes.last)['rtAt'], isNull, reason: 'offline board must not outrank the widget');
    // Same trains, real time back: written again at once, not after widgetRewriteEvery.
    final n = writes.length;
    final back = Board(
        departures: [dep('A', 5, delaySec: 60)],
        destinations: const [],
        missingNucleos: const [],
        rtStale: false,
        feedStale: false,
        feedCoversToday: true);
    await p.publish('Silla', back, now.add(const Duration(seconds: 30)), rtAt: now);
    expect(writes, hasLength(n + 1));
    expect(jsonDecode(writes.last)['rtAt'], now.millisecondsSinceEpoch ~/ 1000);
    // A newer real time alone is not a change.
    await p.publish('Silla', back, now.add(const Duration(seconds: 60)), rtAt: now.add(const Duration(seconds: 30)));
    expect(writes, hasLength(n + 1));
  });

  test('a failed write is tried again', () async {
    var fail = true;
    final writes = <String>[];
    final p = WidgetPublisher(write: (j) async {
      if (fail) throw Exception('no');
      writes.add(j);
    });
    await p.publish('Silla', board([dep('A', 5)]), now);
    fail = false;
    await p.publish('Silla', board([dep('A', 5)]), now);
    expect(writes, hasLength(1));
  });
}

extension on Departure {
  /// Same train, already gone at [now].
  Departure copyLeft(DateTime now) => Departure(
      tripId: tripId,
      line: line,
      dest: dest,
      scheduled: scheduled,
      estimated: tz.TZDateTime.from(now.subtract(const Duration(minutes: 2)), tz.getLocation('Europe/Madrid')),
      delaySec: delaySec,
      live: live,
      canceled: canceled,
      minutes: 0,
      color: color);
}
