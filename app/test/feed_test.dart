import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/feed.dart';

void main() {
  test('parses stops and trips', () {
    final json = jsonDecode(File('test/fixtures/feed.json').readAsStringSync());
    final feed = Feed.fromJson(json as Map<String, dynamic>);
    expect(feed.stops.length, 3);
    expect(feed.trips.length, 2);
    expect(feed.generatedAt, DateTime.utc(2026, 11, 15, 3));
    expect(feed.validFrom, '2026-11-14');
    expect(feed.validTo, '2026-11-22');
    final t = feed.trips[0];
    expect(t.times.first, ('65000', 67200));
    expect(t.dates.contains('2026-11-15'), isTrue);
    expect(t.dir, 'out');
    expect(t.dest, 'Gandia');
    expect(feed.stops[1].name, 'Silla');
    expect(feed.stops[1].lines, ['C1', 'C2']);
    expect(feed.stops[0].lat, closeTo(39.4669305, 1e-9));
  });
}
