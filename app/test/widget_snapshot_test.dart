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
          {int? delaySec, String? live, String? usual, bool canceled = false, StopTime? arrival}) =>
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
      );

  Board board(List<Departure> ds) => Board(
      departures: ds, destinations: const [], missingNucleos: const [], rtStale: false, feedStale: false, feedCoversToday: true);

  test('fields of each train; live platform wins over the usual one', () {
    final s = widgetSnapshot('Silla', board([dep('A', 5, delaySec: 240, live: '2', usual: '1'), dep('B', 9, usual: '3')]), now);
    expect(s['station'], 'Silla');
    expect(s['via'], isNull);
    final trains = s['trains'] as List;
    expect(trains[0], {
      'line': 'C1',
      'color': 0xFF7AB3DE,
      'dest': 'València Nord',
      'dep': t(18, 9).millisecondsSinceEpoch ~/ 1000,
      'sched': t(18, 5).millisecondsSinceEpoch ~/ 1000,
      'delayMin': 4,
      'platform': '2',
      'live': true,
      'canceled': false,
      'arrival': null,
    });
    expect((trains[1] as Map)['platform'], '3');
    expect((trains[1] as Map)['live'], false);
    expect((trains[1] as Map)['delayMin'], isNull);
  });

  test('at most 8, none that already left, arrival with a chosen stop', () {
    final many = [for (var i = 0; i < 12; i++) dep('T$i', i)];
    final s = widgetSnapshot('Silla', board([dep('gone', 0).copyLeft(now), ...many]), t(18, 1));
    final trains = s['trains'] as List;
    expect(trains, hasLength(8));
    expect((trains.first as Map)['dep'], t(18, 1).millisecondsSinceEpoch ~/ 1000);
    final arr = StopTime(stopId: '69110', name: 'Gandia', time: t(18, 50));
    final v = widgetSnapshot('Silla', board([dep('A', 5, arrival: arr)]), now, via: 'Gandia');
    expect(v['via'], 'Gandia');
    expect(((v['trains'] as List).single as Map)['arrival'], t(18, 50).millisecondsSinceEpoch ~/ 1000);
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
    await p.publish('Silla', board([dep('A', 5, delaySec: 120)]), now);
    expect(writes, hasLength(2));
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
