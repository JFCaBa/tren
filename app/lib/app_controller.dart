import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'data/feed.dart';
import 'data/json_cache.dart';
import 'data/nucleo_index.dart';
import 'data/positions.dart';
import 'data/realtime.dart';
import 'domain/board.dart';
import 'domain/nearest.dart';
import 'location.dart';

const _lastStationKey = 'last_station';
const _recentKey = 'recent_stations';

/// Recent stations offered as shortcuts, besides the current one.
const recentShown = 3;

/// Stations remembered, so a few that leave the index still leave [recentShown] to offer.
const _recentKept = 10;
String _filtersKey(String stopId) => 'filters_$stopId';
const rtInterval = Duration(seconds: 30);

/// Trains shown at first, and added each time the list is scrolled to its end.
const pageSize = 8;

typedef PeriodicTimerFactory = Timer Function(Duration, void Function(Timer));

tz.TZDateTime madridNow() => tz.TZDateTime.now(tz.getLocation('Europe/Madrid'));

/// Orchestrates the station index, núcleo schedules, location and realtime,
/// and exposes what the screen shows.
class AppController extends ChangeNotifier {
  AppController(
    this._client,
    this._cacheDir,
    this._rtClient,
    this._location,
    this._prefs, {
    tz.TZDateTime Function()? clock,
    PeriodicTimerFactory? periodic,
    PositionsClient? positions,
  })  : _clock = clock ?? madridNow,
        _positionsClient = positions,
        _periodic = periodic ?? Timer.periodic,
        _indexCache = indexCache(_client, _cacheDir);

  final http.Client _client;
  final Directory _cacheDir;
  final RealtimeClient _rtClient;
  final PositionsClient? _positionsClient;
  final LocationSource _location;
  final SharedPreferences _prefs;
  final tz.TZDateTime Function() _clock;
  final PeriodicTimerFactory _periodic;
  final JsonCache<NucleoIndex> _indexCache;
  final _nucleoCaches = <String, JsonCache<Feed>>{};

  NucleoIndex? index;
  IndexStop? station;

  /// Schedules of the current station's núcleos (never mixed with a previous station's).
  List<Feed> feeds = const [];

  /// Destinations the list is filtered by; empty = all.
  Set<String> filters = {};

  /// How many trains the list shows; grows with [loadMore], back to [pageSize] on a new station or filter.
  int limit = pageSize;
  double? distanceMeters;
  bool manualStation = false;
  Board? board;
  String? error;
  bool needsStationPick = false;
  RtSnapshot? rt;

  /// Last live platforms from Renfe; kept across failed polls, shown while fresh.
  PlatformSnapshot? positions;

  /// True once a realtime poll has answered or failed (no "Sin tiempo real" flash at launch).
  bool rtAttempted = false;
  (double, double)? coords;

  int _locationGen = 0;
  int _stationGen = 0;
  bool _feedsSettled = false;

  /// The station came from last_station while GPS is still pending: show its cache, don't download.
  bool _stationProvisional = false;

  /// A user-requested retry is running.
  bool retrying = false;
  Future<void>? _feedsLoad; // current station's schedule load, if any
  bool _locating = false;
  bool _paused = false;
  Future<void>? _starting;
  bool _started = false;
  Timer? _timer;
  bool _disposed = false;

  tz.TZDateTime now() => _clock();

  String? nucleoName(String id) => index?.nucleo(id)?.name;

  /// Stations shown, newest first (ids, current included).
  late List<String> _recentIds = _loadRecent();

  List<String> _loadRecent() {
    try {
      return (jsonDecode(_prefs.getString(_recentKey) ?? '[]') as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Up to [recentShown] stations shown before the current one, newest first.
  List<IndexStop> get recentStations => [
        for (final id in _recentIds)
          if (id != station?.id) ?_stopById(id),
      ].take(recentShown).toList();

  void _remember(String stopId) {
    if (_recentIds.firstOrNull == stopId) return;
    _recentIds = [stopId, ..._recentIds.where((id) => id != stopId)].take(_recentKept).toList();
    _prefs.setString(_recentKey, jsonEncode(_recentIds));
  }

  /// First load. Safe to call once; later calls return the same future.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _locating = true; // don't ask to pick a station before GPS has had its chance
    index = await _indexCache.loadCached();
    if (_disposed) return;
    _resolveStation();
    _recompute();
    _startTimer();
    await Future.wait([_refreshIndex(), _locate(requestPermission: true), _pollRt()]);
    await _feedsLoad?.catchError((_) {});
    _started = true;
  }

  Future<void> onResume() async {
    _paused = false;
    if (!_started && _starting != null) {
      await _starting; // start() is already doing the work
      _startTimer();
      // A pause during start drops the GPS answer: ask again so a provisional station gets confirmed.
      if (_stationProvisional && !manualStation && !_paused) {
        await _locate();
        await _feedsLoad?.catchError((_) {});
      }
      return;
    }
    _startTimer();
    await Future.wait([_refreshIndex(), if (!manualStation) _locate(), _pollRt(), _reloadFeeds()]);
    await _feedsLoad?.catchError((_) {});
  }

  void onPause() {
    _paused = true;
    _locationGen++; // drop answers that arrive while in the background
    _locating = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> retry() async {
    if (retrying) return;
    retrying = true;
    _recompute();
    try {
      await Future.wait([
        _refreshIndex(),
        if (!manualStation) _locate(requestPermission: true),
        _pollRt(),
        _reloadFeeds(),
      ]);
      await _feedsLoad?.catchError((_) {});
    } finally {
      retrying = false;
      _recompute();
    }
  }

  /// Leave the manual choice and go back to the nearest station.
  Future<void> useLocation() async {
    manualStation = false;
    await _locate(requestPermission: true);
    await _feedsLoad?.catchError((_) {});
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

  void toggleFilter(String dest) {
    final next = {...filters};
    if (!next.remove(dest)) next.add(dest);
    _setFilters(next);
  }

  void clearFilters() => _setFilters({});

  /// Show [pageSize] more trains, if the schedule has them.
  void loadMore() {
    if (board?.hasMore != true) return;
    limit += pageSize;
    _recompute();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _setFilters(Set<String> next) {
    filters = next;
    limit = pageSize;
    final s = station;
    if (s != null) _prefs.setString(_filtersKey(s.id), jsonEncode(next.toList()..sort()));
    _recompute();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _paused) return;
    _timer = _periodic(rtInterval, (_) => _pollRt());
  }

  Future<void> _refreshIndex() async {
    try {
      index = await _indexCache.refresh();
      error = null;
    } on DataUnavailable {
      if (index == null) error = 'No se ha podido descargar el horario. Comprueba la conexión.';
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

  /// A platform only shows up while the train arrives (1–3 min before), so positions (~170 KB) are
  /// only fetched when some train is this close.
  static const positionsWithinMinutes = 5;

  /// Renfe republishes positions every ~30 s with no compression; at busy stations a train is almost
  /// always near, so cap the download at once a minute (a platform is known 1–3 min ahead).
  static const positionsMinInterval = Duration(seconds: 60);
  tz.TZDateTime? _positionsAt;

  Future<void> _pollRt() async {
    final now = _clock();
    final last = _positionsAt;
    final wantPositions = _positionsClient != null &&
        (last == null || now.difference(last).isNegative || now.difference(last) >= positionsMinInterval) &&
        (board?.departures.any((d) => d.minutes <= positionsWithinMinutes) ?? false);
    if (wantPositions) _positionsAt = now;
    await Future.wait([
      () async {
        try {
          rt = await _rtClient.fetch();
        } catch (_) {
          // Board.rtStale reflects it.
        }
      }(),
      if (wantPositions)
        () async {
          try {
            final p = await _positionsClient.fetch();
            final last = positions;
            if (last == null || !p.feedTimestamp.isBefore(last.feedTimestamp)) positions = p; // drop out-of-order answers
          } catch (_) {
            // Keep the last snapshot; platformsAt hides it once stale.
          }
        }(),
    ]);
    if (_disposed) return;
    rtAttempted = true;
    _recompute();
  }

  IndexStop? _stopById(String id) {
    for (final s in index?.stops ?? const <IndexStop>[]) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _resolveStation() {
    final idx = index;
    if (idx == null || idx.stops.isEmpty) return;
    if (manualStation && station != null) {
      _setStation(_stopById(station!.id) ?? station!);
      return;
    }
    final c = coords;
    if (c != null) {
      _setStation(nearest(idx.stops, c.$1, c.$2, latOf: (s) => s.lat, lonOf: (s) => s.lon).$1);
      return;
    }
    final saved = _prefs.getString(_lastStationKey);
    final s = saved == null ? null : _stopById(saved);
    if (s != null) {
      _setStation(s, provisional: _locating);
    } else if (station == null && !_locating) {
      needsStationPick = true; // only once the location attempt has failed
    }
  }

  void _setStation(IndexStop s, {bool provisional = false}) {
    final c = coords;
    distanceMeters = c == null ? null : haversineMeters(c.$1, c.$2, s.lat, s.lon);
    needsStationPick = false;
    final same = station?.id == s.id;
    final nucleosChanged = !same || !listEquals(station!.nucleos, s.nucleos);
    if (same && !nucleosChanged) {
      station = s;
      if (_stationProvisional && !provisional) {
        _stationProvisional = false; // confirmed by GPS or by the user: now download it
        _remember(s.id);
        _feedsLoad = _loadFeeds(s, ++_stationGen);
      }
      return;
    }
    _stationProvisional = provisional;
    station = s;
    _prefs.setString(_lastStationKey, s.id);
    if (!provisional) _remember(s.id);
    if (!same) {
      filters = _savedFilters(s.id);
      limit = pageSize;
    }
    feeds = const [];
    _feedsSettled = false;
    final gen = ++_stationGen;
    _feedsLoad = _loadFeeds(s, gen, network: !provisional);
  }

  Set<String> _savedFilters(String stopId) {
    try {
      return {...(jsonDecode(_prefs.getString(_filtersKey(stopId)) ?? '[]') as List).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> _reloadFeeds() {
    final s = station;
    if (s == null || _stationProvisional) return Future.value();
    return _feedsLoad = _loadFeeds(s, _stationGen);
  }

  /// One cache per núcleo and feed path (a new path in the index gets a new cache).
  JsonCache<Feed> _cacheFor(String nucleo) {
    final path = index?.nucleo(nucleo)?.feedPath;
    return _nucleoCaches.putIfAbsent('$nucleo|$path', () => nucleoCache(_client, _cacheDir, nucleo, path: path));
  }

  /// Cache first, then network. Results for a station the user already left are dropped.
  Future<void> _loadFeeds(IndexStop s, int gen, {bool network = true}) async {
    final caches = [for (final n in s.nucleos) _cacheFor(n)];
    final cached = await Future.wait(caches.map((c) => c.loadCached()));
    if (gen != _stationGen || _disposed) return;
    if (feeds.isEmpty) {
      feeds = cached.whereType<Feed>().toList();
      _recompute();
    }
    if (!network) return;
    final fresh = await Future.wait(caches.map((c) async {
      try {
        return await c.refresh();
      } on DataUnavailable {
        return null;
      }
    }));
    if (gen != _stationGen || _disposed) return;
    feeds = [
      for (var i = 0; i < caches.length; i++)
        if ((fresh[i] ?? cached[i]) != null) (fresh[i] ?? cached[i])!,
    ];
    _feedsSettled = true;
    _recompute();
    _reconcileFilters(s);
  }

  /// Drop saved destinations that no longer exist, once every núcleo of the station is loaded.
  void _reconcileFilters(IndexStop s) {
    final b = board;
    if (b == null || filters.isEmpty || feeds.length < s.nucleos.length) return;
    final all = b.destinations.toSet(); // computed before the filter is applied
    final kept = filters.where(all.contains).toSet();
    if (kept.length != filters.length) _setFilters(kept);
  }

  void _recompute() {
    final s = station;
    board = (s == null || (feeds.isEmpty && !_feedsSettled))
        ? null
        : computeBoard(feeds, s.id, _clock(), rt,
            destinations: filters,
            limit: limit,
            requiredNucleos: s.nucleos,
            livePlatforms: platformsAt(positions, s.id, _clock()));
    if (!_disposed) notifyListeners();
  }
}
