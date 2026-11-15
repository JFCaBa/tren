import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class RtTrip {
  const RtTrip({required this.delaySec, required this.canceled});

  /// Trip-level delay in seconds (negative = early); null if Renfe gave none.
  final int? delaySec;
  final bool canceled;
}

class RtSnapshot {
  const RtSnapshot({required this.fetchedAt, required this.feedTimestamp, required this.trips});

  final DateTime fetchedAt;

  /// The feed's own `header.timestamp`.
  final DateTime feedTimestamp;
  final Map<String, RtTrip> trips;

  RtSnapshot refetched(DateTime at) => RtSnapshot(fetchedAt: at, feedTimestamp: feedTimestamp, trips: trips);
}

int? _int(Object? v) => switch (v) {
      int i => i,
      num n => n.toInt(),
      String s => int.tryParse(s),
      _ => null,
    };

RtSnapshot parseTripUpdates(Map<String, dynamic> json, DateTime fetchedAt) {
  final ts = _int((json['header'] as Map?)?['timestamp']) ?? 0;
  final trips = <String, RtTrip>{};
  for (final e in (json['entity'] as List? ?? const [])) {
    final tu = (e as Map)['tripUpdate'] as Map?;
    final trip = tu?['trip'] as Map?;
    final id = trip?['tripId'] as String?;
    if (tu == null || id == null) continue;
    trips[id] = RtTrip(
      delaySec: _int(tu['delay']),
      canceled: trip!['scheduleRelationship'] == 'CANCELED',
    );
  }
  return RtSnapshot(
    fetchedAt: fetchedAt,
    feedTimestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
    trips: trips,
  );
}

class RealtimeClient {
  RealtimeClient(this._client);

  final http.Client _client;
  String? _etag;
  RtSnapshot? _last;

  Future<RtSnapshot> fetch() async {
    final headers = <String, String>{if (_etag != null && _last != null) 'If-None-Match': _etag!};
    final resp = await _client.get(Uri.parse(rtUrl), headers: headers).timeout(const Duration(seconds: 10));
    final now = DateTime.now().toUtc();
    if (resp.statusCode == 304 && _last != null) return _last = _last!.refetched(now);
    if (resp.statusCode != 200) throw http.ClientException('realtime HTTP ${resp.statusCode}');
    final snap = parseTripUpdates(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>, now);
    _etag = resp.headers['etag'];
    return _last = snap;
  }
}
