import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/follow/follow_logic.dart';
import 'package:proximotren/follow/follow_tracker.dart';

import 'support.dart';

void main() {
  final train = FollowedTrain(
      tripId: 'T1', stopId: '18101', scheduled: DateTime.utc(2026, 11, 21, 8, 12), title: '09:12 a Guadalajara', route: const [('18000', 'Atocha'), ('18101', 'Mine')]);
  late FakeFollower follower;
  late TimerLog timers;
  late List<TrainReading> answers;
  late int calls;
  late FollowTracker tracker;

  setUp(() {
    follower = FakeFollower();
    timers = TimerLog();
    answers = [];
    calls = 0;
    tracker = FollowTracker(
      follower: follower,
      periodic: timers.create,
      clock: () => DateTime.utc(2026, 11, 21, 8, 0),
      fetch: (t, s) async {
        calls++;
        if (answers.isEmpty) throw Exception('offline');
        return answers.removeAt(0);
      },
    );
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('idle until a train is followed, then reads it every 30 s', () async {
    await settle();
    expect((calls, timers.active), (0, 0));
    answers.add(const TrainReading(delaySec: 300, seen: (stopId: '18000', status: 'STOPPED_AT')));
    await follower.follow(train);
    await settle();
    expect(calls, 1);
    expect(tracker.reading!.delaySec, 300);
    answers.add(const TrainReading(delaySec: 300, platform: '4'));
    timers.fireActive();
    await settle();
    expect(tracker.reading!.platform, '4');
  });

  test('platform sticks, errors keep the last reading, delay kept when Renfe drops the trip', () async {
    answers.add(const TrainReading(delaySec: 300, platform: '4'));
    await follower.follow(train);
    await settle();
    timers.fireActive(); // offline
    await settle();
    expect(tracker.reading!.platform, '4');
    answers.add(const TrainReading());
    timers.fireActive();
    await settle();
    expect((tracker.reading!.platform, tracker.reading!.delaySec), ('4', 300));
  });

  test('stops following once the train has left', () async {
    final now = DateTime.utc(2026, 11, 21, 8, 20);
    final t = FollowTracker(
        follower: follower,
        periodic: TimerLog().create,
        clock: () => now,
        fetch: (a, b) async => const TrainReading(delaySec: 0, seen: (stopId: '99999', status: 'STOPPED_AT')));
    await follower.follow(train);
    await settle();
    await settle();
    expect(follower.current, isNull);
    t.dispose();
  });

  test('stops when unfollowed and in the background', () async {
    answers.add(const TrainReading());
    await follower.follow(train);
    await settle();
    await follower.stop();
    expect((timers.active, tracker.reading), (0, null));
    answers.add(const TrainReading());
    await follower.follow(train);
    await settle();
    tracker.onBackground();
    expect(timers.active, 0);
    answers.add(const TrainReading());
    tracker.onForeground();
    await settle();
    expect(timers.active, 1);
  });
}
