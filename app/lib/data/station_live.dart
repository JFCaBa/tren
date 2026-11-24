import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'positions.dart';
import 'realtime.dart';

/// One station's realtime from our server (`GET /anden/live/{stop}`): the same snapshots the board
/// builds from Renfe's whole feeds, for that station's trains only.
typedef StationLive = ({RtSnapshot rt, PlatformSnapshot? positions});

DateTime _epoch(Object? v) {
  if (v is! int) throw const FormatException('timestamp');
  return DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
}

T _as<T>(Object? v, String what) => v is T ? v : throw FormatException(what);

/// Throws [FormatException] on any unexpected shape: the caller then reads Renfe directly.
StationLive parseStationLive(Map<String, dynamic> json, DateTime fetchedAt, {String stopId = ''}) {
  final trips = <String, RtTrip>{};
  for (final e in _as<Map>(json['trips'], 'trips').entries) {
    final t = _as<Map>(e.value, 'trip');
    final delay = t['delay'];
    if (delay != null && delay is! int) throw const FormatException('delay');
    trips[_as<String>(e.key, 'tripId')] = RtTrip(delaySec: delay as int?, canceled: t['cancelled'] == true);
  }
  final rt = RtSnapshot(fetchedAt: fetchedAt, feedTimestamp: _epoch(json['tripsAt']), trips: trips);
  if (json['positionsAt'] == null) return (rt: rt, positions: null);
  final byTrip = <String, LivePlatform>{};
  for (final e in _as<Map>(json['platforms'], 'platforms').entries) {
    final p = _as<Map>(e.value, 'platform');
    byTrip[_as<String>(e.key, 'tripId')] =
        (stopId: stopId, platform: _as<String>(p['platform'], 'platform'), at: _epoch(p['at']));
  }
  return (
    rt: rt,
    positions: PlatformSnapshot(fetchedAt: fetchedAt, feedTimestamp: _epoch(json['positionsAt']), byTrip: byTrip),
  );
}

class StationLiveClient {
  StationLiveClient(this._client, {this.baseUrl = apiBaseUrl, DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  final http.Client _client;
  final String baseUrl;
  final DateTime Function() _now;

  /// Short: the answer comes from the server's memory; on failure the board reads Renfe itself.
  static const timeout = Duration(seconds: 5);

  Future<StationLive> fetch(String stopId) async {
    final resp = await _client
        .get(Uri.parse('$baseUrl/live/${Uri.encodeComponent(stopId)}'), headers: const {'User-Agent': userAgent})
        .timeout(timeout);
    if (resp.statusCode != 200) throw http.ClientException('live HTTP ${resp.statusCode}');
    final json = jsonDecode(utf8.decode(resp.bodyBytes));
    if (json is! Map<String, dynamic>) throw const FormatException('live body');
    return parseStationLive(json, _now(), stopId: stopId);
  }
}
