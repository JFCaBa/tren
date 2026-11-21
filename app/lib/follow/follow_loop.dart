import 'follow_logic.dart';

const followMaxDuration = Duration(hours: 3);
const cancelledLinger = Duration(minutes: 2);
const afterDeparture = Duration(minutes: 2);

/// One reading per [tick] of the followed train: alerts on changes, keeps the ongoing notification
/// current and says when following should end. Driven by Android's foreground service.
class FollowLoop {
  FollowLoop({
    required this.train,
    required this.startedAt,
    required this.fetch,
    required this.alert,
    required this.ongoing,
    required this.clock,
  });

  final FollowedTrain train;
  final DateTime startedAt;
  final Future<TrainReading> Function(String tripId, String stopId) fetch;
  final Future<void> Function(String title, String body) alert;
  final Future<void> Function(String title, String text) ongoing;
  final DateTime Function() clock;

  TrainReading? _last;

  /// What alerts were last computed against: small delay steps add up until they are news.
  TrainReading? _alerted;
  DateTime? _cancelledAt;
  bool _busy = false;

  /// False when following must stop.
  Future<bool> tick() async {
    if (_busy) return true;
    final now = clock();
    if (!now.isBefore(startedAt.add(followMaxDuration))) return false;
    _busy = true;
    try {
      TrainReading r;
      try {
        r = await fetch(train.tripId, train.stopId);
      } catch (_) {
        return true; // offline or server trouble: try again next tick
      }
      final before = _last;
      if (before != null && (!r.live || (r.delaySec == null && !r.canceled))) {
        // Renfe's delay feed is down, or it dropped the trip for a while: keep what we knew.
        r = TrainReading(delaySec: before.delaySec, canceled: r.live ? r.canceled : before.canceled, seen: r.seen, platform: r.platform);
      }
      // Renfe shows a platform only while the train arrives: once announced it stays.
      r = r.withPlatform(r.platform ?? before?.platform);
      _last = r;
      _cancelledAt = r.canceled ? (_cancelledAt ?? now) : null;
      final texts = changes(before == null ? null : _alerted, r);
      final base = _alerted;
      _alerted = texts.isNotEmpty || base == null
          ? r
          : TrainReading(delaySec: base.delaySec, canceled: r.canceled, platform: r.platform);
      for (final body in texts) {
        await _safely(() => alert(train.title, body));
      }
      final at = clock();
      await _safely(() => ongoing(ongoingTitle(train, r), ongoingText(train, r, at.toUtc())));
      final cancelledAt = _cancelledAt;
      if (cancelledAt != null) return at.isBefore(cancelledAt.add(cancelledLinger));
      return !hasLeft(train, r, at.toUtc(), afterDeparture);
    } finally {
      _busy = false;
    }
  }

  Future<void> _safely(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      // a notification that could not be shown must not end the follow
    }
  }
}
