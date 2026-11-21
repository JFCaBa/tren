import '../data/positions.dart';

/// Where the followed train is, against its stops from its first one up to and including the
/// user's (`stopId`): "En Atocha · a 2 paradas", "Hacia Getafe Centro · a 1 parada", "Llegando",
/// "En la estación"; null when Renfe doesn't place it on those stops. Same texts as the server
/// (server/anden_api/live.py), which feeds the Live Activity.
String? whereText(List<(String, String)> stops, String stopId, TrainSighting? pos) {
  if (pos == null || stops.isEmpty || stops.last.$1 != stopId) return null;
  final i = stops.indexWhere((s) => s.$1 == pos.stopId);
  if (i < 0) return null;
  final j = stops.length - 1;
  if (i == j) return pos.status == 'STOPPED_AT' ? 'En la estación' : 'Llegando';
  final n = j - i;
  final lead = pos.status == 'STOPPED_AT' ? 'En' : 'Hacia';
  return '$lead ${stops[i].$2} · ${n == 1 ? 'a 1 parada' : 'a $n paradas'}';
}

/// "A su hora", "Retraso 5 min", "Cancelado", or "" without live data.
String liveStatusText({int? delaySec, required bool canceled}) {
  if (canceled) return 'Cancelado';
  if (delaySec == null) return '';
  final m = (delaySec / 60).round();
  return m >= 1 ? 'Retraso $m min' : 'A su hora';
}

/// The Live Activity's content state (twin of the server's `content_state`).
Map<String, Object?> contentState({
  required DateTime scheduled,
  int? delaySec,
  required bool canceled,
  String? livePlatform,
  String? usualPlatform,
  String? where,
}) =>
    {
      'departs': canceled ? null : scheduled.millisecondsSinceEpoch ~/ 1000 + (delaySec ?? 0),
      'status': liveStatusText(delaySec: delaySec, canceled: canceled),
      'platform': livePlatform ?? usualPlatform,
      'usual': livePlatform == null && usualPlatform != null,
      'where': canceled ? null : where,
      'cancelled': canceled,
    };
