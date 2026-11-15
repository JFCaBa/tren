import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'data/feed.dart';
import 'data/feed_repository.dart';
import 'data/realtime.dart';
import 'domain/board.dart';
import 'domain/nearest.dart';
import 'location.dart';

const _lastStationKey = 'last_station';
const rtInterval = Duration(seconds: 30);

typedef PeriodicTimerFactory = Timer Function(Duration, void Function(Timer));

tz.TZDateTime madridNow() => tz.TZDateTime.now(tz.getLocation('Europe/Madrid'));

/// Orchestrates feed, location and realtime, and exposes what the screen shows.
class AppController extends ChangeNotifier {
  AppController(
    this._repo,
    this._rtClient,
    this._location,
    this._prefs, {
    tz.TZDateTime Function()? clock,
    PeriodicTimerFactory? periodic,
  })  : _clock = clock ?? madridNow,
        _periodic = periodic ?? Timer.periodic;

  final FeedRepository _repo;
  final RealtimeClient _rtClient;
  final LocationSource _location;
  final SharedPreferences _prefs;
  final tz.TZDateTime Function() _clock;
  final PeriodicTimerFactory _periodic;

  Feed? feed;
  Stop? station;
  double? distanceMeters;
  bool manualStation = false;
  Board? board;
  String? error;
  bool needsStationPick = false;
  RtSnapshot? rt;

  /// True once a realtime poll has answered or failed (no "Sin tiempo real" flash at launch).
  bool rtAttempted = false;
  (double, double)? coords;

  int _locationGen = 0;
  bool _locating = false;
  bool _paused = false;
  Future<void>? _starting;
  bool _started = false;
  Timer? _timer;
  bool _disposed = false;

  tz.TZDateTime now() => _clock();

  /// First load. Safe to call once; later calls return the same future.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _locating = true; // don't ask to pick a station before GPS has had its chance
    feed = await _repo.loadCached();
    if (_disposed) return;
    _resolveStation();
    _recompute();
    _startTimer();
    await Future.wait([_refreshFeed(), _locate(requestPermission: true), _pollRt()]);
    _started = true;
  }

  Future<void> onResume() async {
    _paused = false;
    if (!_started && _starting != null) {
      await _starting; // start() is already doing the work
      _startTimer();
      return;
    }
    _startTimer();
    await Future.wait([_refreshFeed(), if (!manualStation) _locate(), _pollRt()]);
  }

  void onPause() {
    _paused = true;
    _locationGen++; // drop answers that arrive while in the background
    _locating = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> retry() =>
      Future.wait([_refreshFeed(), if (!manualStation) _locate(requestPermission: true), _pollRt()]);

  /// Leave the manual choice and go back to the nearest station.
  Future<void> useLocation() {
    manualStation = false;
    return _locate(requestPermission: true);
  }

  void selectStation(String stopId) {
    final s = _stopById(stopId);
    if (s == null) return;
    _locationGen++;
    _locating = false;
    manualStation = true;
    _setStation(s);
    _recompute();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _paused) return;
    _timer = _periodic(rtInterval, (_) => _pollRt());
  }

  Future<void> _refreshFeed() async {
    try {
      feed = await _repo.refresh();
      error = null;
    } on FeedUnavailable {
      if (feed == null) error = 'No se ha podido descargar el horario. Comprueba la conexión.';
    }
    _resolveStation();
    _recompute();
  }

  Future<void> _locate({bool requestPermission = false}) async {
    final gen = ++_locationGen;
    _locating = true;
    final c = await _location.current(requestPermission: requestPermission);
    if (gen != _locationGen || manualStation || _disposed) return;
    _locating = false;
    coords = c;
    _resolveStation();
    _recompute();
  }

  Future<void> _pollRt() async {
    try {
      rt = await _rtClient.fetch();
    } catch (_) {
      // Board.rtStale reflects it.
    }
    rtAttempted = true;
    _recompute();
  }

  Stop? _stopById(String id) {
    for (final s in feed?.stops ?? const <Stop>[]) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _resolveStation() {
    final f = feed;
    if (f == null || f.stops.isEmpty) return;
    if (manualStation && station != null) {
      _setStation(_stopById(station!.id) ?? station!);
      return;
    }
    final c = coords;
    if (c != null) {
      _setStation(nearestStop(f.stops, c.$1, c.$2).$1);
      return;
    }
    final saved = _prefs.getString(_lastStationKey);
    final s = saved == null ? null : _stopById(saved);
    if (s != null) {
      _setStation(s);
    } else if (station == null && !_locating) {
      needsStationPick = true; // only once the location attempt has failed
    }
  }

  void _setStation(Stop s) {
    station = s;
    needsStationPick = false;
    final c = coords;
    distanceMeters = c == null ? null : haversineMeters(c.$1, c.$2, s.lat, s.lon);
    _prefs.setString(_lastStationKey, s.id);
  }

  void _recompute() {
    final f = feed, s = station;
    board = (f != null && s != null) ? computeBoard(f, s.id, _clock(), rt) : null;
    if (!_disposed) notifyListeners();
  }
}
