import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/feed.dart';

Map<String, dynamic> load(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('parses v2 feed with line colors', () {
    final feed = Feed.fromJson(load('feed_40.json'));
    expect(feed.nucleo, '40');
    expect(feed.name, 'Valencia');
    expect(feed.lineColors['C1'], 0xFF7AB3DE);
    expect(feed.lineColors['C2'], 0xFFF79529);
    expect(feed.stops.length, 4);
    expect(feed.trips.length, 3);
    expect(feed.generatedAt, DateTime.utc(2026, 11, 15, 3));
    final t = feed.trips[0];
    expect(t.times.first, ('65000', 67200));
    expect(t.dates.contains('2026-11-15'), isTrue);
    expect(t.dest, 'Gandia');
  });

  test('invalid line color falls back to grey', () {
    final j = load('feed_40.json');
    (j['lines'] as Map)['C1'] = 'zz';
    expect(Feed.fromJson(j).lineColors['C1'], 0xFF9E9E9E);
  });

  test('missing lines map is tolerated', () {
    final j = load('feed_40.json')..remove('lines');
    expect(Feed.fromJson(j).lineColors, isEmpty);
  });

  test('rejects v1 feed', () {
    final j = load('feed_40.json')..['version'] = 1;
    expect(() => Feed.fromJson(j), throwsFormatException);
  });
}
