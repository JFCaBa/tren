import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/data/positions.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(File('test/fixtures/vehicle_positions.json').readAsStringSync()) as Map<String, dynamic>;

final feedTime = DateTime.fromMillisecondsSinceEpoch(1794816746 * 1000, isUtc: true);

void main() {
  test('parses platforms of arriving or stopped trains only', () {
    final s = parsePositions(fixture(), feedTime);
    expect(s.byTrip.keys.toSet(), {'3019L23525C1', '1017S35905C2'});
    expect(s.byTrip['3019L23525C1']!.stopId, '51200');
    expect(s.byTrip['3019L23525C1']!.platform, '6');
    expect(s.byTrip['1017S35905C2']!.platform, '2AM');
    expect(s.feedTimestamp, feedTime);
  });

  test('platformsAt keeps only the station asked for', () {
    final s = parsePositions(fixture(), feedTime);
    expect(platformsAt(s, '51200', feedTime), {'3019L23525C1': '6'});
    expect(platformsAt(s, '99999', feedTime), isEmpty);
    expect(platformsAt(null, '51200', feedTime), isEmpty);
  });

  test('platformsAt drops a stale snapshot', () {
    final s = parsePositions(fixture(), feedTime);
    expect(platformsAt(s, '51200', feedTime.add(const Duration(minutes: 3))), isEmpty);
  });

  test('platformsAt drops a stale vehicle in a fresh feed', () {
    final j = fixture();
    ((j['entity'] as List)[0] as Map)['vehicle']['timestamp'] = '${1794816746 - 180}';
    final s = parsePositions(j, feedTime);
    expect(platformsAt(s, '51200', feedTime), isEmpty);
  });

  test('malformed entities are ignored', () {
    final s = parsePositions({'header': {'timestamp': '1794816746'}, 'entity': [{}, 'x', {'vehicle': {}}]}, feedTime);
    expect(s.byTrip, isEmpty);
  });

  test('304 returns the previous snapshot', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls == 1) {
        return http.Response.bytes(utf8.encode(File('test/fixtures/vehicle_positions.json').readAsStringSync()), 200,
            headers: {'etag': '"a"'});
      }
      expect(req.headers['If-None-Match'], '"a"');
      return http.Response('', 304);
    });
    final c = PositionsClient(client, now: () => feedTime);
    final first = await c.fetch();
    final second = await c.fetch();
    expect(second.byTrip, first.byTrip);
  });
}
