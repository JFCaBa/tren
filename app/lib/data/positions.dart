import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Renfe vehicle positions: the label carries the platform ("C1-23525-PLATF.(6)") of the stop the
/// train is arriving at or standing in.
final _label = RegExp(r'^([A-Za-z0-9]+)-(\d+)(?:-PLATF\.\(([^)]*)\))?$');
const _statuses = {'INCOMING_AT', 'STOPPED_AT'};

/// A live platform older than this is not shown (same freshness as the realtime delays).
const positionsMaxAge = Duration(minutes: 2);

typedef LivePlatform = ({String stopId, String platform, DateTime at});

/// Where a train is: at (STOPPED_AT), arriving at (INCOMING_AT) or on its way to (IN_TRANSIT_TO) a stop.
typedef TrainSighting = ({String stopId, String status});

const _seenStatuses = {'INCOMING_AT', 'STOPPED_AT', 'IN_TRANSIT_TO'};

class PlatformSnapshot {
  const PlatformSnapshot(
      {required this.fetchedAt, required this.feedTimestamp, required this.byTrip, this.seen = const {}});

  final DateTime fetchedAt;
  final DateTime feedTimestamp;

  /// tripId -> where the train is and its platform there.
  final Map<String, LivePlatform> byTrip;

  /// tripId -> where every train in the feed is, with or without a platform.
  final Map<String, TrainSighting> seen;

  PlatformSnapshot refetched(DateTime at) =>
      PlatformSnapshot(fetchedAt: at, feedTimestamp: feedTimestamp, byTrip: byTrip, seen: seen);
}

DateTime? _epoch(Object? v) {
  final s = switch (v) { int i => i, num n => n.toInt(), String s => int.tryParse(s), _ => null };
  return s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

PlatformSnapshot parsePositions(Map<String, dynamic> json, DateTime fetchedAt) {
  final feedTs = _epoch((json['header'] as Map?)?['timestamp']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final byTrip = <String, LivePlatform>{};
  final seen = <String, TrainSighting>{};
  for (final e in (json['entity'] as List? ?? const [])) {
    if (e is! Map) continue;
    final v = e['vehicle'];
    if (v is! Map) continue;
    final tripId = (v['trip'] as Map?)?['tripId'];
    final stopId = v['stopId'];
    final status = v['currentStatus'];
    if (tripId is String && stopId is String && stopId != '00000' && status is String && _seenStatuses.contains(status)) {
      seen[tripId] = (stopId: stopId, status: status);
    }
    if (!_statuses.contains(status)) continue;
    final label = (v['vehicle'] as Map?)?['label'];
    if (tripId is! String || stopId is! String || stopId == '00000' || label is! String) continue;
    final platform = _label.firstMatch(label.trim())?.group(3)?.trim();
    if (platform == null || platform.isEmpty) continue;
    byTrip[tripId] = (stopId: stopId, platform: platform, at: _epoch(v['timestamp']) ?? feedTs);
  }
  return PlatformSnapshot(fetchedAt: fetchedAt, feedTimestamp: feedTs, byTrip: byTrip, seen: seen);
}

/// tripId -> platform for trains reported at [stopId], if the data is fresh at [now].
Map<String, String> platformsAt(PlatformSnapshot? s, String stopId, DateTime now) {
  if (s == null || now.difference(s.fetchedAt) > positionsMaxAge || now.difference(s.feedTimestamp) > positionsMaxAge) {
    return const {};
  }
  return {
    for (final e in s.byTrip.entries)
      if (e.value.stopId == stopId && now.difference(e.value.at) <= positionsMaxAge) e.key: e.value.platform,
  };
}

class PositionsClient {
  PositionsClient(this._client, {DateTime Function()? now}) : _now = now ?? (() => DateTime.now().toUtc());

  final http.Client _client;
  final DateTime Function() _now;
  String? _etag;
  PlatformSnapshot? _last;

  Future<PlatformSnapshot> fetch() async {
    final headers = <String, String>{if (_etag != null && _last != null) 'If-None-Match': _etag!};
    final resp = await _client.get(Uri.parse(positionsUrl), headers: headers).timeout(const Duration(seconds: 10));
    final now = _now();
    if (resp.statusCode == 304 && _last != null) return _last = _last!.refetched(now);
    if (resp.statusCode != 200) throw http.ClientException('positions HTTP ${resp.statusCode}');
    final snap = parsePositions(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>, now);
    _etag = resp.headers['etag'];
    return _last = snap;
  }
}
