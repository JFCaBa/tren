import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/data/station_live.dart';

void main() {
  final now = DateTime.utc(2026, 11, 24, 12);
  final body = {
    'tripsAt': 1795521600,
    'trips': {
      'T1': {'delay': 120, 'cancelled': false},
      'T2': {'delay': null, 'cancelled': true},
    },
    'positionsAt': 1795521590,
    'platforms': {
      'T1': {'platform': '6', 'at': 1795521580},
    },
  };

  test('parses delays and platforms', () {
    final live = parseStationLive(body, now, stopId: '18000');
    expect(live.rt.fetchedAt, now);
    expect(live.rt.feedTimestamp, DateTime.fromMillisecondsSinceEpoch(1795521600 * 1000, isUtc: true));
    expect(live.rt.trips['T1']!.delaySec, 120);
    expect(live.rt.trips['T2']!.canceled, isTrue);
    expect(live.rt.trips['T2']!.delaySec, isNull);
    final p = live.positions!;
    expect(p.feedTimestamp, DateTime.fromMillisecondsSinceEpoch(1795521590 * 1000, isUtc: true));
    expect(p.byTrip['T1'], (stopId: '18000', platform: '6', at: DateTime.fromMillisecondsSinceEpoch(1795521580 * 1000, isUtc: true)));
  });

  test('no positionsAt: no positions', () {
    final live = parseStationLive({...body, 'positionsAt': null, 'platforms': {}}, now);
    expect(live.positions, isNull);
  });

  test('wrong shapes throw', () {
    for (final bad in <Map<String, dynamic>>[
      {...body, 'trips': []},
      {...body, 'tripsAt': 'x'},
      {...body, 'tripsAt': null},
      {...body, 'trips': {'T1': 3}},
      {...body, 'platforms': {'T1': {'platform': 6}}},
    ]) {
      expect(() => parseStationLive(bad, now), throwsFormatException, reason: '$bad');
    }
  });

  test('fetch asks our server for the station', () async {
    final urls = <Uri>[];
    final client = StationLiveClient(MockClient((req) async {
      urls.add(req.url);
      return http.Response(jsonEncode(body), 200);
    }), now: () => now);
    final live = await client.fetch('18000');
    expect(urls.single.toString(), 'https://api.whatplatform.uk/anden/live/18000');
    expect(live.positions!.byTrip['T1']!.stopId, '18000');
  });

  test('non-200 throws', () async {
    final client = StationLiveClient(MockClient((_) async => http.Response('x', 503)), now: () => now);
    await expectLater(client.fetch('18000'), throwsA(isA<http.ClientException>()));
  });
}
