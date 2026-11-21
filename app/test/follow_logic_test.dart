import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/follow/follow_logic.dart';
import 'package:proximotren/follow/follow_loop.dart';

const route = [('10000', 'Chamartín'), ('18000', 'Atocha'), ('18002', 'Getafe Centro'), ('18101', 'Mine')];
final sched = DateTime.utc(2026, 11, 21, 8, 12);
final train = FollowedTrain(tripId: 'T1', stopId: '18101', scheduled: sched, title: '09:12 a Guadalajara', usualPlatform: '2', route: route);

TrainReading r({int? delay, bool canceled = false, String? platform, (String, String)? seen, bool live = true}) => TrainReading(
    live: live, delaySec: delay, canceled: canceled, platform: platform, seen: seen == null ? null : (stopId: seen.$1, status: seen.$2));

void main() {
  test('json round trip, also the POST body', () {
    final j = train.toJson();
    expect(j, {
      'tripId': 'T1',
      'stopId': '18101',
      'scheduled': sched.millisecondsSinceEpoch ~/ 1000,
      'title': '09:12 a Guadalajara',
      'usual': '2',
      'stops': [for (final (id, n) in route) [id, n]],
    });
    final back = FollowedTrain.fromJson(j);
    expect(back, train);
    expect(back.route, route);
  });

  test('changes', () {
    expect(changes(null, r(delay: 600, platform: '3')), isEmpty);
    expect(changes(r(), r(platform: '3')), ['Vía 3']);
    expect(changes(r(platform: '3'), r(platform: '5')), ['Cambio de vía: 3 → 5']);
    expect(changes(r(delay: 60), r(delay: 420)), ['Retraso de 7 min']);
    expect(changes(r(delay: 420), r(delay: 60)), ['Va a su hora']);
    expect(changes(r(delay: 240), r(delay: 300)), isEmpty);
    expect(changes(r(), r(delay: 300)), ['Retraso de 5 min']);
    expect(changes(r(), r(canceled: true, platform: '4')), ['Cancelado']);
    expect(changes(r(canceled: true), r(canceled: true)), isEmpty);
  });

  test('reading from the server', () {
    final x = TrainReading.fromJson({
      'live': true,
      'delay': 300,
      'cancelled': false,
      'seen': {'stopId': '18101', 'status': 'INCOMING_AT', 'platform': '4'},
    })!;
    expect((x.delaySec, x.canceled, x.platform, x.seen), (300, false, '4', (stopId: '18101', status: 'INCOMING_AT')));
    expect(TrainReading.fromJson({'live': false, 'delay': null, 'cancelled': false, 'seen': null})!.live, isFalse);
    expect(TrainReading.fromJson('x'), isNull);
  });

  test('ongoing texts', () {
    final now = sched.subtract(const Duration(minutes: 7));
    expect(ongoingTitle(train, r()), '09:12 a Guadalajara · Vía 2 (habitual)');
    expect(ongoingTitle(train, r(platform: '4')), '09:12 a Guadalajara · Vía 4');
    expect(ongoingText(train, r(delay: 300, seen: ('18000', 'STOPPED_AT')), now), '12 min · Retraso 5 min · En Atocha · a 2 paradas');
    expect(ongoingText(train, r(delay: 0), now), '7 min · A su hora');
    expect(ongoingText(train, null, sched), 'Ahora');
    expect(ongoingText(train, r(canceled: true), now), 'Cancelado');
  });

  group('loop', () {
    late DateTime now;
    late List<Object> answers;
    late List<String> alerts, ongoing;
    late FollowLoop loop;
    setUp(() {
      now = sched.subtract(const Duration(minutes: 10));
      answers = [];
      alerts = [];
      ongoing = [];
      loop = FollowLoop(
        train: train,
        startedAt: now,
        clock: () => now,
        fetch: (t, s) async {
          final a = answers.removeAt(0);
          if (a is TrainReading) return a;
          throw a;
        },
        alert: (t, b) async => alerts.add(b),
        ongoing: (t, x) async => ongoing.add('$t | $x'),
      );
    });

    Future<bool> tick(Object answer, [Duration after = Duration.zero]) {
      now = now.add(after);
      answers.add(answer);
      return loop.tick();
    }

    test('first reading quiet, then alerts; platform sticks', () async {
      expect(await tick(r(delay: 0)), isTrue);
      expect(alerts, isEmpty);
      await tick(r(delay: 0, platform: '4', seen: ('18101', 'INCOMING_AT')), const Duration(seconds: 30));
      expect(alerts, ['Vía 4']);
      await tick(r(delay: 0, seen: ('18101', 'STOPPED_AT')), const Duration(seconds: 30));
      expect(alerts, ['Vía 4']);
      expect(ongoing.last, startsWith('09:12 a Guadalajara · Vía 4 |'));
    });

    test('a slowly growing delay adds up to an alert', () async {
      for (final d in [0, 60, 120, 180]) {
        await tick(r(delay: d), const Duration(seconds: 30));
      }
      expect(alerts, ['Retraso de 2 min']);
    });

    test('errors are silent', () async {
      await tick(r(delay: 0));
      expect(await tick(Exception('offline'), const Duration(seconds: 30)), isTrue);
      expect(alerts, isEmpty);
    });

    test('delay feed down keeps the known delay', () async {
      await tick(r(delay: 300));
      await tick(r(live: false), const Duration(seconds: 30));
      expect(alerts, isEmpty);
      expect(ongoing.last, contains('Retraso 5 min'));
    });

    test('ends after departure unless Renfe still places it before us', () async {
      await tick(r());
      expect(await tick(r(seen: ('18002', 'STOPPED_AT')), const Duration(minutes: 13)), isTrue);
      expect(await tick(r(seen: ('18101', 'STOPPED_AT')), const Duration(seconds: 30)), isFalse);
    });

    test('a train Renfe has no news of gets 15 min before it counts as gone', () async {
      await tick(r());
      expect(await tick(r(), const Duration(minutes: 13)), isTrue); // 3 min past, nothing known
      expect(await tick(r(), const Duration(minutes: 13)), isFalse); // 16 min past
    });

    test('ends 2 min after a cancellation', () async {
      await tick(r());
      expect(await tick(r(canceled: true)), isTrue);
      expect(alerts, ['Cancelado']);
      expect(await tick(r(canceled: true), const Duration(minutes: 2)), isFalse);
    });

    test('ends after 3 h', () async {
      now = now.add(const Duration(hours: 3));
      expect(await loop.tick(), isFalse);
    });
  });
}
