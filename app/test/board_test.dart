import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/feed.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/domain/board.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

late tz.Location madrid;

const nord = Stop(id: '65000', name: 'València Nord', lat: 39.4669, lon: -0.3772);
const silla = Stop(id: '64200', name: 'Silla', lat: 39.3620, lon: -0.4150);
const gandia = Stop(id: '69110', name: 'Gandia', lat: 38.9705, lon: -0.1798);

int hm(int h, int m) => h * 3600 + m * 60;

Trip out(String id, int secsAtSilla, {Set<String> dates = const {'2026-11-15'}, String line = 'C1'}) => Trip(
      id: id,
      line: line,
      dest: 'Gandia',
      dates: dates,
      times: [('65000', secsAtSilla - 900), ('64200', secsAtSilla), ('69110', secsAtSilla + 2700)],
    );

Trip inb(String id, int secsAtSilla, {Set<String> dates = const {'2026-11-15'}}) => Trip(
      id: id,
      line: 'C2',
      dest: 'València Nord',
      dates: dates,
      times: [('64200', secsAtSilla), ('65000', secsAtSilla + 900)],
    );

Feed feedOf(List<Trip> trips,
        {DateTime? generatedAt,
        String validTo = '2026-11-22',
        String nucleo = '40',
        List<Stop> stops = const [nord, silla, gandia],
        Map<String, int> colors = const {'C1': 0xFF7AB3DE, 'C2': 0xFFF79529},
        Map<String, Map<String, String>> platforms = const {}}) =>
    Feed(
      nucleo: nucleo,
      name: 'N$nucleo',
      lineColors: colors,
      generatedAt: generatedAt ?? DateTime.utc(2026, 11, 15, 3),
      validFrom: '2026-11-14',
      validTo: validTo,
      stops: stops,
      trips: trips,
      platforms: platforms,
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

  test('orders all departures by estimated time and limits to 8', () {
    final trips = [for (var i = 9; i >= 0; i--) i.isEven ? out('o$i', hm(18, 10 + i)) : inb('i$i', hm(18, 10 + i))];
    final b = computeBoard([feedOf(trips)], '64200', now(), null);
    expect(b.departures.map((d) => d.tripId), ['o0', 'i1', 'o2', 'i3', 'o4', 'i5', 'o6', 'i7']);
    expect(b.departures.first.minutes, 10);
    expect(b.departures.first.dest, 'Gandia');
    expect(b.departures.first.line, 'C1');
  });

  test('filters by destinations (OR)', () {
    final f = feedOf([out('o', hm(18, 10)), inb('i', hm(18, 5))]);
    expect(computeBoard([f], '64200', now(), null, destinations: {'Gandia'}).departures.map((d) => d.tripId), ['o']);
    expect(computeBoard([f], '64200', now(), null, destinations: {'Gandia', 'València Nord'}).departures.map((d) => d.tripId),
        ['i', 'o']);
  });

  test('destinations sorted by frequency', () {
    final f = feedOf([out('o1', hm(18, 10)), out('o2', hm(18, 40)), inb('i', hm(18, 5))]);
    expect(computeBoard([f], '64200', now(), null).destinations, ['Gandia', 'València Nord']);
  });

  test('destinations stay available when filtered out', () {
    final f = feedOf([out('o', hm(18, 10)), inb('i', hm(18, 5))]);
    expect(computeBoard([f], '64200', now(), null, destinations: {'Gandia'}).destinations, hasLength(2));
  });

  test('merges departures of several feeds', () {
    const cist = Stop(id: '05761', name: 'Cistierna', lat: 42.8, lon: -5.1);
    const end = Stop(id: 'E', name: 'Fin', lat: 42.0, lon: -5.0);
    Trip t(String id, int s) => Trip(id: id, line: 'C1', dest: 'Fin', dates: const {'2026-11-15'}, times: [('05761', s), ('E', s + 600)]);
    final a = feedOf([t('L', hm(18, 10))], nucleo: '47', stops: const [cist, end]);
    final b = feedOf([t('B', hm(18, 5))], nucleo: '60', stops: const [cist, end]);
    expect(computeBoard([a, b], '05761', now(), null).departures.map((d) => d.tripId), ['B', 'L']);
  });

  test('departure color comes from its feed', () {
    final d = computeBoard([feedOf([inb('i', hm(18, 5))])], '64200', now(), null).departures.single;
    expect(d.color, 0xFFF79529);
    final grey = computeBoard([feedOf([inb('i', hm(18, 5))], colors: const {})], '64200', now(), null);
    expect(grey.departures.single.color, 0xFF9E9E9E);
  });

  test('reports missing nucleos', () {
    final b = computeBoard([feedOf([out('o', hm(18, 10))], nucleo: '47')], '64200', now(), null, requiredNucleos: ['47', '60']);
    expect(b.departures, hasLength(1));
    expect(b.missingNucleos, ['60']);
  });

  test('usual platform from the feed, live platform from the caller', () {
    final f = feedOf([out('3019L23525C1', hm(18, 10))], platforms: const {'64200': {'23525': '1'}});
    final d = computeBoard([f], '64200', now(), null).departures.single;
    expect(d.usualPlatform, '1');
    expect(d.livePlatform, isNull);
    final live = computeBoard([f], '64200', now(), null, livePlatforms: const {'3019L23525C1': '3'}).departures.single;
    expect(live.livePlatform, '3');
    expect(live.usualPlatform, '1');
  });

  test('usual platform of another station is not used', () {
    final f = feedOf([out('3019L23525C1', hm(18, 10))], platforms: const {'65000': {'23525': '4'}});
    expect(computeBoard([f], '64200', now(), null).departures.single.usualPlatform, isNull);
  });

  test('test_excludes_trips_terminating_at_stop', () {
    final b = computeBoard([feedOf([inb('i', hm(18, 5)), out('o', hm(18, 30))])], '65000', now(), null);
    expect(b.departures.map((d) => d.tripId), ['o']);
  });

  test('test_includes_previous_service_day_after_midnight', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-14'})]);
    final b = computeBoard([f], '64200', at(2026, 11, 15, 0, 20), null);
    expect(b.departures.single.tripId, 'night');
    expect(b.departures.single.minutes, 10);
    expect(b.departures.single.scheduled, at(2026, 11, 15, 0, 30));
  });

  test('applies positive delay and marks live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 540, canceled: false)}, now());
    final d = computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt).departures.single;
    expect(d.live, isTrue);
    expect(d.delaySec, 540);
    expect(d.estimated, at(2026, 11, 15, 18, 19));
    expect(d.minutes, 19);
  });

  test('test_negative_delay', () {
    final rt = rtOf({'a': const RtTrip(delaySec: -180, canceled: false)}, now());
    final d = computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt).departures.single;
    expect(d.delaySec, -180);
    expect(d.estimated, at(2026, 11, 15, 18, 7));
    expect(d.minutes, 7);
  });

  test('stale realtime falls back to scheduled', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 540, canceled: false)}, at(2026, 11, 15, 17, 57));
    final b = computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt);
    expect(b.rtStale, isTrue);
    final d = b.departures.single;
    expect(d.live, isFalse);
    expect(d.delaySec, isNull);
    expect(d.estimated, d.scheduled);
  });

  test('stale feed timestamp is not live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 60, canceled: false)}, now(), feedTs: at(2026, 11, 15, 17, 55));
    final b = computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt);
    expect(b.rtStale, isTrue);
    expect(b.departures.single.live, isFalse);
  });

  test('fresh realtime is not stale', () {
    final rt = rtOf({}, now());
    expect(computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt).rtStale, isFalse);
    expect(computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), null).rtStale, isTrue);
  });

  test('trip without delay is not live', () {
    final rt = rtOf({'a': const RtTrip(delaySec: null, canceled: false)}, now());
    expect(computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt).departures.single.live, isFalse);
  });

  test('ambiguous trip id ignores realtime', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 300, canceled: true)}, now());
    final d = computeBoard([feedOf([out('a', hm(18, 10), dates: {'2026-11-15', '2026-11-16'})])], '64200', now(), rt)
        .departures
        .first;
    expect(d.live, isFalse);
    expect(d.canceled, isFalse);
  });

  test('canceled trip shown as canceled', () {
    final rt = rtOf({'a': const RtTrip(delaySec: null, canceled: true)}, now());
    final b = computeBoard([feedOf([out('a', hm(18, 10)), out('b', hm(18, 20))])], '64200', now(), rt);
    expect(b.departures.map((d) => (d.tripId, d.canceled)), [('a', true), ('b', false)]);
  });

  test('train within last minute still shown', () {
    final b1 = computeBoard([feedOf([out('a', hm(18, 0))])], '64200', at(2026, 11, 15, 18, 0, 30), null);
    expect(b1.departures.single.minutes, 0);
    final b2 = computeBoard([feedOf([out('a', hm(18, 0))])], '64200', at(2026, 11, 15, 18, 1, 30), null);
    expect(b2.departures, isEmpty);
  });

  test('late night shows tomorrow first trains', () {
    final f = feedOf([out('early', hm(5, 30), dates: {'2026-11-16'})]);
    final d = computeBoard([f], '64200', at(2026, 11, 15, 23, 50), null).departures.single;
    expect(d.tripId, 'early');
    expect(d.scheduled, at(2026, 11, 16, 5, 30));
  });

  test('dst spring forward', () {
    final f = feedOf([out('a', 36000, dates: {'2027-03-28'})], validTo: '2027-03-30');
    final d = computeBoard([f], '64200', at(2027, 3, 28, 6, 0), null).departures.single;
    expect(d.scheduled.hour, 10);
    expect(d.scheduled.minute, 0);
  });

  test('dst fall back', () {
    final f = feedOf([out('a', 36000, dates: {'2026-10-25'})], validTo: '2026-10-27');
    final d = computeBoard([f], '64200', at(2026, 10, 25, 6, 0), null).departures.single;
    expect(d.scheduled.hour, 10);
    expect(d.scheduled.minute, 0);
  });

  test('month boundary uses previous month service day', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-30'})], validTo: '2026-12-05');
    final d = computeBoard([f], '64200', at(2026, 12, 1, 0, 20), null).departures.single;
    expect(d.scheduled, at(2026, 12, 1, 0, 30));
  });

  test('uses Madrid service day whatever zone now is in', () {
    final f = feedOf([out('night', 88200, dates: {'2026-11-14'})]);
    final utcNow = tz.TZDateTime.from(at(2026, 11, 15, 0, 20), tz.UTC); // 23:20 UTC on the 14th
    final d = computeBoard([f], '64200', utcNow, null).departures.single;
    expect(d.tripId, 'night');
    expect(d.minutes, 10);
    expect(d.scheduled.location.name, 'Europe/Madrid');
  });

  test('departure lists stops from the station to the end with delay', () {
    final rt = rtOf({'a': const RtTrip(delaySec: 120, canceled: false)}, now());
    final d = computeBoard([feedOf([out('a', hm(18, 10))])], '64200', now(), rt).departures.single;
    expect(d.stops.map((s) => s.name), ['Silla', 'Gandia']);
    expect(d.stops.first.time, at(2026, 11, 15, 18, 12));
    expect(d.stops.last.time, at(2026, 11, 15, 18, 57));
  });

  test('scheduled departure stops use scheduled times', () {
    final d = computeBoard([feedOf([out('a', hm(18, 30))])], '65000', now(), null).departures.single;
    expect(d.stops.map((s) => s.name), ['València Nord', 'Silla', 'Gandia']);
    expect(d.stops.first.time, at(2026, 11, 15, 18, 15));
  });

  test('terminating trips do not offer their destination', () {
    final b = computeBoard([feedOf([inb('i', hm(18, 5)), out('o', hm(18, 30))])], '65000', now(), null);
    expect(b.destinations, ['Gandia']);
  });

  test('no feeds means not covering today', () {
    expect(computeBoard([], '64200', now(), null).feedCoversToday, isFalse);
  });

  test('feed staleness flags', () {
    final fresh = computeBoard([feedOf([])], '64200', now(), null);
    expect(fresh.feedStale, isFalse);
    expect(fresh.feedCoversToday, isTrue);
    final old = computeBoard(
        [feedOf([], generatedAt: DateTime.utc(2026, 11, 11), validTo: '2026-11-14')], '64200', now(), null);
    expect(old.feedStale, isTrue);
    expect(old.feedCoversToday, isFalse);
  });
}
