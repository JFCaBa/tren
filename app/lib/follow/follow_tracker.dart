// Private fields set from public named parameters: initializing formals can't be private.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_controller.dart' show PeriodicTimerFactory;
import 'follow_logic.dart';
import 'follow_loop.dart' show afterDeparture;
import 'follower.dart';

/// The followed train as the home screen shows it, read from our server every [every] while the
/// app is in the foreground: delay, cancellation, platform (kept once announced) and where it is.
class FollowTracker extends ChangeNotifier {
  FollowTracker({
    required Follower follower,
    required Future<TrainReading> Function(String tripId, String stopId) fetch,
    PeriodicTimerFactory periodic = Timer.periodic,
    DateTime Function()? clock,
  })  : _follower = follower,
        _fetch = fetch,
        _periodic = periodic,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    _follower.addListener(_onFollow);
    _onFollow();
  }

  static const every = Duration(seconds: 30);

  final Follower _follower;
  final Future<TrainReading> Function(String tripId, String stopId) _fetch;
  final PeriodicTimerFactory _periodic;
  final DateTime Function() _clock;

  FollowedTrain? _train;
  TrainReading? _reading;
  Timer? _timer;
  bool _foreground = true;
  bool _busy = false;
  bool _disposed = false;

  FollowedTrain? get train => _train;

  /// The latest reading of [train]; null until one arrives.
  TrainReading? get reading => _reading;

  void onForeground() {
    _foreground = true;
    _restart();
  }

  void onBackground() {
    _foreground = false;
    _timer?.cancel();
    _timer = null;
  }

  void _onFollow() {
    final t = _follower.current;
    if (t == _train) return;
    _train = t;
    _reading = null;
    _restart();
    _notify();
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (_train == null || !_foreground || _disposed) return;
    _timer = _periodic(every, (_) => _tick());
    _tick();
  }

  Future<void> _tick() async {
    final t = _train;
    if (t == null || _busy) return;
    _busy = true;
    try {
      final r = await _fetch(t.tripId, t.stopId);
      if (t != _train) return;
      final last = _reading;
      var next = r.withPlatform(r.platform ?? last?.platform);
      if (last != null && (!r.live || (r.delaySec == null && !r.canceled))) {
        next = TrainReading(delaySec: last.delaySec, canceled: r.live ? r.canceled : last.canceled, seen: r.seen, platform: next.platform);
      }
      _reading = next;
      _notify();
      // The train has left: stop following, as Android's service and our server do.
      if (hasLeft(t, next, _clock(), afterDeparture) && _follower.current == t) unawaited(_follower.stop());
    } catch (_) {
      // keep the last reading
    } finally {
      _busy = false;
      if (_train != null && _train != t && !_disposed) unawaited(_tick());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _follower.removeListener(_onFollow);
    super.dispose();
  }
}
