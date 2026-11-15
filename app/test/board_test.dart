import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/feed.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/domain/board.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

late tz.Location madrid;

const nord = Stop(id: '65000', name: 'València Nord', lat: 39.4669, lon: -0.3772, lines: ['C1', 'C2']);
const silla = Stop(id: '64200', name: 'Silla', lat: 39.3620, lon: -0.4150, lines: ['C1', 'C2']);
const gandia = Stop(id: '69110', name: 'Gandia', lat: 38.9705, lon: -0.1798, lines: ['C1']);

int hm(int h, int m) => h * 3600 + m * 60;

Trip out(String id, int secsAtSilla, {Set<String> dates = const {'2026-11-15'}, String line = 'C1'}) => Trip(
      id: id,
      line: line,
      dir: 'out',
      dest: 'Gandia',
      dates: dates,
      times: [('65000', secsAtSilla - 900), ('64200', secsAtSilla), ('69110', secsAtSilla + 2700)],
    );

Trip inb(String id, int secsAtSilla, {Set<String> dates = const {'2026-11-15'}}) => Trip(
      id: id,
      line: 'C2',
      dir: 'in',
      dest: 'València Nord',
      dates: dates,
      times: [('64200', secsAtSilla), ('65000', secsAtSilla + 900)],
    );

Feed feedOf(List<Trip> trips, {DateTime? generatedAt, String validTo = '2026-11-22'}) => Feed(
      generatedAt: generatedAt ?? DateTime.utc(2026, 11, 15, 3),
      validFrom: '2026-11-14',
      validTo: validTo,
      stops: const [nord, silla, gandia],
      trips: trips,
    );

tz.TZDateTime at(int y, int mo, int d, int h, int mi, [int s = 0]) => tz.TZDateTime(madrid, y, mo, d, h, mi, s);

RtSnapshot rtOf(Map<String, RtTrip> trips, tz.TZDateTime fetched, {tz.TZDateTime? feedTs}) =>
    RtSnapshot(fetchedAt: fetched.toUtc(), feedTimestamp: (feedTs ?? fetched).toUtc(), trips: trips);

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    madrid = tz.getLocation('Europe/Madrid');
  });

  tz.TZDateTime now() => at(2026, 11, 15, 18, 0);

  test('orders and limits to 3 per direction', () {
    final f = feedOf([out('d', hm(18, 40)), out('a', hm(18, 10)), out('c', hm(18, 30)), out('b', hm(18, 20))]);
    final b = computeBoard(f, '64200', now(), null);
    expect(b.fromValencia!.map((d) => d.tripId), ['a', 'b', 'c']);
    expect(b.fromValencia!.first.minutes, 10);
    expect(b.fromValencia!.first.dest, 'Gandia');
    expect(b.fromValencia!.first.line, 'C1');
  });

  test('splits by direction', () {
    final b = computeBoard(feedOf([out('o', hm(18, 10)), inb('i', hm(18, 5))]), '64200', now(), null);
    expect(b.toValencia!.map((d) => d.tripId), ['i']);
    expect(b.fromValencia!.map((d) => d.tripId), ['o']);
  });

  test('test_excludes_trips_terminating_at_stop', () {
    final b = computeBoard(feedOf([inb('i', hm(18, 5)), out('o', hm(18, 30))]), '65000', now(), null);
    expect(b.fromValencia!.map((d) => d.tripId), ['o']);
    expect(b.toValencia, isNull);
  });

  test('test_includes_previous_service_day_after_midnight', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-14'})]);
    final b = computeBoard(f, '64200', at(2026, 11, 15, 0, 20), null);
    expect(b.fromValencia!.single.tripId, 'night');
    expect(b.fromValencia!.single.minutes, 10);
    expect(b.fromValencia!.single.scheduled, at(2026, 11, 15, 0, 30));
  });

  test('applies positive delay and marks live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 540, canceled: false)}, now());
    final d = computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt).fromValencia!.single;
    expect(d.live, isTrue);
    expect(d.delaySec, 540);
    expect(d.estimated, at(2026, 11, 15, 18, 19));
    expect(d.minutes, 19);
  });

  test('test_negative_delay', () {
    final rt = rtOf({'a': const RtTrip(delaySec: -180, canceled: false)}, now());
    final d = computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt).fromValencia!.single;
    expect(d.delaySec, -180);
    expect(d.estimated, at(2026, 11, 15, 18, 7));
    expect(d.minutes, 7);
  });

  test('stale realtime falls back to scheduled', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 540, canceled: false)}, at(2026, 11, 15, 17, 57));
    final b = computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt);
    expect(b.rtStale, isTrue);
    final d = b.fromValencia!.single;
    expect(d.live, isFalse);
    expect(d.delaySec, isNull);
    expect(d.estimated, d.scheduled);
  });

  test('stale feed timestamp is not live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 60, canceled: false)}, now(), feedTs: at(2026, 11, 15, 17, 55));
    final b = computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt);
    expect(b.rtStale, isTrue);
    expect(b.fromValencia!.single.live, isFalse);
  });

  test('fresh realtime is not stale', () {
    final rt = rtOf({}, now());
    expect(computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt).rtStale, isFalse);
    expect(computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), null).rtStale, isTrue);
  });

  test('trip without delay is not live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: null, canceled: false)}, now());
    expect(computeBoard(feedOf([out('a', hm(18, 10))]), '64200', now(), rt).fromValencia!.single.live, isFalse);
  });

  test('ambiguous trip id ignores realtime', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 300, canceled: true)}, now());
    final d = computeBoard(feedOf([out('a', hm(18, 10), dates: {'2026-11-15', '2026-11-16'})]), '64200', now(), rt)
        .fromValencia!
        .first;
    expect(d.live, isFalse);
    expect(d.canceled, isFalse);
  });

  test('canceled trip shown as canceled', () {
    final rt = rtOf({'a': const RtTrip(delaySec: null, canceled: true)}, now());
    final b = computeBoard(feedOf([out('a', hm(18, 10)), out('b', hm(18, 20))]), '64200', now(), rt);
    expect(b.fromValencia!.map((d) => (d.tripId, d.canceled)), [('a', true), ('b', false)]);
  });

  test('train within last minute still shown', () {
    final b1 = computeBoard(feedOf([out('a', hm(18, 0))]), '64200', at(2026, 11, 15, 18, 0, 30), null);
    expect(b1.fromValencia!.single.minutes, 0);
    final b2 = computeBoard(feedOf([out('a', hm(18, 0))]), '64200', at(2026, 11, 15, 18, 1, 30), null);
    expect(b2.fromValencia, isEmpty);
  });

  test('late night shows tomorrow first trains', () {
    final f = feedOf([out('early', hm(5, 30), dates: {'2026-11-16'})]);
    final d = computeBoard(f, '64200', at(2026, 11, 15, 23, 50), null).fromValencia!.single;
    expect(d.tripId, 'early');
    expect(d.scheduled, at(2026, 11, 16, 5, 30));
  });

  test('dst spring forward', () {
    final f = feedOf([out('a', 36000, dates: {'2027-03-28'})], validTo: '2027-03-30');
    final d = computeBoard(f, '64200', at(2027, 3, 28, 6, 0), null).fromValencia!.single;
    expect(d.scheduled.hour, 10);
    expect(d.scheduled.minute, 0);
  });

  test('dst fall back', () {
    final f = feedOf([out('a', 36000, dates: {'2026-10-25'})], validTo: '2026-10-27');
    final d = computeBoard(f, '64200', at(2026, 10, 25, 6, 0), null).fromValencia!.single;
    expect(d.scheduled.hour, 10);
    expect(d.scheduled.minute, 0);
  });

  test('month boundary uses previous month service day', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-30'})], validTo: '2026-12-05');
    final d = computeBoard(f, '64200', at(2026, 12, 1, 0, 20), null).fromValencia!.single;
    expect(d.scheduled, at(2026, 12, 1, 0, 30));
  });

  test('uses Madrid service day whatever zone now is in', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-14'})]);
    final utcNow = tz.TZDateTime.from(at(2026, 11, 15, 0, 20), tz.UTC); // 23:20 UTC on the 14th
    final d = computeBoard(f, '64200', utcNow, null).fromValencia!.single;
    expect(d.tripId, 'night');
    expect(d.minutes, 10);
    expect(d.scheduled.location.name, 'Europe/Madrid');
  });

  test('terminal hides direction', () {
    final b = computeBoard(feedOf([inb('i', hm(18, 5)), out('o', hm(18, 30))]), '65000', now(), null);
    expect(b.toValencia, isNull);
    expect(b.fromValencia, isNotEmpty);
  });

  test('feed staleness flags', () {
    final fresh = computeBoard(feedOf([]), '64200', now(), null);
    expect(fresh.feedStale, isFalse);
    expect(fresh.feedCoversToday, isTrue);
    final old = computeBoard(
        feedOf([], generatedAt: DateTime.utc(2026, 11, 11), validTo: '2026-11-14'), '64200', now(), null);
    expect(old.feedStale, isTrue);
    expect(old.feedCoversToday, isFalse);
  });
}
