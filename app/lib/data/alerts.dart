import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// One service alert from Renfe (GTFS-RT `alerts.json`).
class RenfeAlert {
  const RenfeAlert({required this.text, this.routeIds = const [], this.stopIds = const [], this.start, this.end});

  final String text;

  /// Renfe route ids it affects, e.g. `10T0013C4a` (núcleo 10, line C4a).
  final List<String> routeIds;
  final List<String> stopIds;
  final DateTime? start;
  final DateTime? end;
}

DateTime? _epoch(Object? v) {
  final s = switch (v) {
    int i => i,
    num n => n.toInt(),
    String s => int.tryParse(s),
    _ => null,
  };
  return s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

/// Tolerant: entities that are not alerts or have no Spanish (or any) text are dropped.
List<RenfeAlert> parseAlerts(Map<String, dynamic> json) {
  final out = <RenfeAlert>[];
  for (final e in (json['entity'] as List? ?? const [])) {
    if (e is! Map || e['alert'] is! Map) continue;
    final a = e['alert'] as Map;
    final translations = [
      for (final t in ((a['descriptionText'] as Map?)?['translation'] as List? ?? const []))
        if (t is Map && t['text'] is String) t,
    ];
    if (translations.isEmpty) continue;
    final es = translations.where((t) => t['language'] == 'es').firstOrNull ?? translations.first;
    final text = (es['text'] as String).trim();
    if (text.isEmpty) continue;
    final entities = [for (final i in (a['informedEntity'] as List? ?? const [])) if (i is Map) i];
    final periods = [for (final p in (a['activePeriod'] as List? ?? const [])) if (p is Map) p];
    out.add(RenfeAlert(
      text: text,
      routeIds: [for (final i in entities) if (i['routeId'] is String) i['routeId'] as String],
      stopIds: [for (final i in entities) if (i['stopId'] is String) i['stopId'] as String],
      start: periods.isEmpty ? null : _epoch(periods.first['start']),
      end: periods.isEmpty ? null : _epoch(periods.first['end']),
    ));
  }
  return out;
}

class AlertsClient {
  AlertsClient(this._client);

  final http.Client _client;
  String? _etag;
  List<RenfeAlert>? _last;

  Future<List<RenfeAlert>> fetch() async {
    final headers = <String, String>{if (_etag != null && _last != null) 'If-None-Match': _etag!};
    final resp = await _client.get(Uri.parse(alertsUrl), headers: headers).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 304 && _last != null) return _last!;
    if (resp.statusCode != 200) throw http.ClientException('alerts HTTP ${resp.statusCode}');
    final alerts = parseAlerts(jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>);
    _etag = resp.headers['etag'];
    return _last = alerts;
  }
}
