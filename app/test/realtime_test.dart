import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/data/realtime.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(File('test/fixtures/trip_updates.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final fetchedAt = DateTime.utc(2026, 11, 15, 18, 45);

  test('trip-level delay', () {
    final snap = parseTripUpdates(fixture(), fetchedAt);
    expect(snap.trips['T1']!.delaySec, 540);
    expect(snap.trips['T1']!.canceled, isFalse);
  });

  test('string numbers parsed', () {
    expect(parseTripUpdates(fixture(), fetchedAt).trips['T2']!.delaySec, -180);
  });

  test('missing trip delay is null', () {
    expect(parseTripUpdates(fixture(), fetchedAt).trips['T3']!.delaySec, isNull);
  });

  test('canceled trip', () {
    final t = parseTripUpdates(fixture(), fetchedAt).trips['T4']!;
    expect(t.canceled, isTrue);
    expect(t.delaySec, isNull);
  });

  test('header timestamp parsed', () {
    final snap = parseTripUpdates(fixture(), fetchedAt);
    expect(snap.feedTimestamp, DateTime.fromMillisecondsSinceEpoch(1794768264 * 1000, isUtc: true));
    expect(snap.fetchedAt, fetchedAt);
  });

  test('304 reuses previous snapshot', () async {
    final body = File('test/fixtures/trip_updates.json').readAsStringSync();
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      if (req.headers['If-None-Match'] == '"v1"') return http.Response('', 304);
      return http.Response(body, 200, headers: {'etag': '"v1"'});
    });
    final rt = RealtimeClient(client);
    final first = await rt.fetch();
    final second = await rt.fetch();
    expect(requests.length, 2);
    expect(requests[0].headers.containsKey('If-None-Match'), isFalse);
    expect(requests[1].headers['If-None-Match'], '"v1"');
    expect(second.trips.keys, first.trips.keys);
    expect(second.feedTimestamp, first.feedTimestamp);
    expect(second.fetchedAt.isBefore(first.fetchedAt), isFalse);
  });
}
