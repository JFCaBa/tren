import 'package:timezone/timezone.dart' as tz;

import '../data/positions.dart';
import '../domain/board.dart';
import '../domain/position.dart';

/// The one train being followed: one trip on one day, at the user's station.
class FollowedTrain {
  const FollowedTrain({
    required this.tripId,
    required this.stopId,
    required this.scheduled,
    required this.title,
    this.usualPlatform,
    this.route = const [],
  });

  final String tripId;
  final String stopId;

  /// Scheduled departure from [stopId], UTC.
  final DateTime scheduled;

  /// "08:12 a Guadalajara"
  final String title;
  final String? usualPlatform;

  /// (stopId, name) from the first stop up to and including [stopId].
  final List<(String, String)> route;

  factory FollowedTrain.of(Departure d, String stopId) => FollowedTrain(
        tripId: d.tripId,
        stopId: stopId,
        scheduled: d.scheduled.toUtc(),
        title: '${_hhmm(d.scheduled)} a ${d.dest}',
        usualPlatform: d.usualPlatform,
        route: d.route,
      );

  factory FollowedTrain.fromJson(Map<String, dynamic> j) => FollowedTrain(
        tripId: j['tripId'] as String,
        stopId: j['stopId'] as String,
        scheduled: DateTime.fromMillisecondsSinceEpoch((j['scheduled'] as int) * 1000, isUtc: true),
        title: j['title'] as String,
        usualPlatform: j['usual'] as String?,
        route: [for (final s in (j['stops'] as List? ?? const [])) ((s as List)[0] as String, s[1] as String)],
      );

  /// Also the body of POST /follow (plus token, env, startedAt, activityToken).
  Map<String, dynamic> toJson() => {
        'tripId': tripId,
        'stopId': stopId,
        'scheduled': scheduled.millisecondsSinceEpoch ~/ 1000,
        'title': title,
        'usual': ?usualPlatform,
        'stops': [
          for (final (id, name) in route) [id, name],
        ],
      };

  /// The same train on a board: same trip and same scheduled departure (a trip id repeats daily).
  bool matches(Departure d) => d.tripId == tripId && d.scheduled.isAtSameMomentAs(scheduled);

  @override
  bool operator ==(Object other) =>
      other is FollowedTrain && other.tripId == tripId && other.stopId == stopId && other.scheduled == scheduled;

  @override
  int get hashCode => Object.hash(tripId, stopId, scheduled);
}

String _hhmm(tz.TZDateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// What Renfe says now about the followed train (GET /anden/train/{tripId}/{stopId}).
class TrainReading {
  const TrainReading({this.live = true, this.delaySec, this.canceled = false, this.seen, this.platform});

  /// Renfe's delay feed was readable.
  final bool live;
  final int? delaySec;
  final bool canceled;
  final TrainSighting? seen;

  /// Live platform at the user's station, once announced (kept by the follower).
  final String? platform;

  static TrainReading? fromJson(Object? j) {
    if (j is! Map) return null;
    final seen = j['seen'];
    final delay = j['delay'];
    TrainSighting? s;
    String? platform;
    if (seen is Map && seen['stopId'] is String && seen['status'] is String) {
      s = (stopId: seen['stopId'] as String, status: seen['status'] as String);
      platform = seen['platform'] is String ? seen['platform'] as String : null;
    }
    return TrainReading(
      live: j['live'] != false,
      delaySec: delay is num ? delay.toInt() : null,
      canceled: j['cancelled'] == true,
      seen: s,
      platform: platform,
    );
  }

  TrainReading withPlatform(String? p) =>
      TrainReading(live: live, delaySec: delaySec, canceled: canceled, seen: seen, platform: p);
}

/// Swings in Renfe's delay smaller than this are noise, not news.
const delayStep = 2;

int? _minutes(int? sec) => sec == null ? null : (sec / 60).round();

/// Alerts between two readings: platform first, then time; a newly cancelled train gives only the
/// cancellation; none on the first reading. Same texts as the server (live.py `changes`).
List<String> changes(TrainReading? before, TrainReading after) {
  if (before == null) return const [];
  if (after.canceled) return before.canceled ? const [] : const ['Cancelado'];
  final out = <String>[];
  final p0 = before.platform, p1 = after.platform;
  if (p1 != null && p1 != p0) out.add(p0 == null ? 'Vía $p1' : 'Cambio de vía: $p0 → $p1');
  final m0 = _minutes(before.delaySec), m1 = _minutes(after.delaySec);
  if (m1 != null) {
    if (m0 == null) {
      if (m1 >= delayStep) out.add('Retraso de $m1 min');
    } else if ((m1 - m0).abs() >= delayStep) {
      out.add(m1 >= delayStep ? 'Retraso de $m1 min' : 'Va a su hora');
    }
  }
  return out;
}

/// Expected departure: scheduled plus Renfe's delay.
DateTime expectedDeparture(FollowedTrain t, TrainReading? r) => t.scheduled.add(Duration(seconds: r?.delaySec ?? 0));

/// "12 min", "1 min", "Ahora".
String waitText(DateTime departs, DateTime nowUtc) {
  final m = (departs.difference(nowUtc).inSeconds / 60).floor();
  return m <= 0 ? 'Ahora' : '$m min';
}

/// Renfe places the train on its stops up to ours (and not standing at ours, about to leave).
bool beforeUs(FollowedTrain t, TrainSighting? s) {
  if (s == null) return false;
  final i = t.route.indexWhere((r) => r.$1 == s.stopId);
  if (i < 0) return false;
  return i < t.route.length - 1 || s.status != 'STOPPED_AT';
}

/// Without a delay from Renfe, a train not seen anywhere may just be late: wait this long after
/// its scheduled time before taking it as gone.
const unseenGrace = Duration(minutes: 15);

/// The followed train has left: past its expected departure (plus [after]), and Renfe doesn't
/// place it on its stops up to ours; a train Renfe doesn't place at all gets [unseenGrace].
bool hasLeft(FollowedTrain t, TrainReading? r, DateTime nowUtc, Duration after) {
  if (beforeUs(t, r?.seen)) return false;
  final departs = expectedDeparture(t, r);
  final wait = r?.seen == null && r?.delaySec == null ? unseenGrace : after;
  return !nowUtc.isBefore(departs.add(wait));
}

/// Android's ongoing notification: "08:12 a Guadalajara · Vía 3" / "Vía 2 (habitual)".
String ongoingTitle(FollowedTrain t, TrainReading? r) {
  final live = r?.platform;
  if (live != null) return '${t.title} · Vía $live';
  final usual = t.usualPlatform;
  return usual == null ? t.title : '${t.title} · Vía $usual (habitual)';
}

/// "12 min · Retraso 5 min · En Atocha · a 2 paradas"; "Cancelado".
String ongoingText(FollowedTrain t, TrainReading? r, DateTime nowUtc) {
  if (r?.canceled == true) return 'Cancelado';
  final status = liveStatusText(delaySec: r?.delaySec, canceled: false);
  return [
    waitText(expectedDeparture(t, r), nowUtc),
    if (status.isNotEmpty) status,
    ?whereText(t.route, t.stopId, r?.seen),
  ].join(' · ');
}
