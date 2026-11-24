import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'data/alerts.dart';
import 'data/feed.dart';
import 'data/json_cache.dart';
import 'data/nucleo_index.dart';
import 'data/positions.dart';
import 'data/realtime.dart';
import 'data/station_live.dart';
import 'domain/alerts.dart';
import 'domain/board.dart';
import 'domain/nearest.dart';
import 'location.dart';
import 'widget/next_trains_widget.dart' show widgetTrains;

const _lastStationKey = 'last_station';
const _recentKey = 'recent_stations';
const _seenPlatformsKey = 'seen_platforms';

/// Renfe shows a platform only while the train arrives, and sometimes drops it while the train
/// stands there: once seen, it is kept this long (the board shows it only within 15 min anyway).
const rememberPlatformFor = Duration(minutes: 20);

/// Recent stations offered as shortcuts, besides the current one.
const recentShown = 3;

/// Stations remembered, so a few that leave the index still leave [recentShown] to offer.
const _recentKept = 10;
String _filtersKey(String stopId) => 'filters_$stopId';
String _viaKey(String stopId) => 'via_$stopId';
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
    AlertsClient? alerts,
    StationLiveClient? live,
  })  : _clock = clock ?? madridNow,
        _positionsClient = positions,
        _liveClient = live,
        _alertsClient = alerts,
        _periodic = periodic ?? Timer.periodic,
        _indexCache = indexCache(_client, _cacheDir);

  final http.Client _client;
  final Directory _cacheDir;
  final RealtimeClient _rtClient;
  final PositionsClient? _positionsClient;

  /// Our server's per-station realtime; Renfe's whole feeds are the fallback.
  final StationLiveClient? _liveClient;
  final AlertsClient? _alertsClient;
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

  /// Stop the user is going to («Otra parada…»): only trains that reach it, with their arrival.
  /// Excludes [filters].
  String? via;

  /// Name of [via], from the stops this station reaches.
  String? get viaName {
    final v = via;
    if (v == null) return null;
    for (final (id, name) in board?.reachable ?? const <(String, String)>[]) {
      if (id == v) return name;
    }
    return null;
  }

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

  /// Station [rt] / [positions] cover when they came from our server (only that station's
  /// trains); null when they are Renfe's whole feeds.
  String? _rtStop, _positionsStop;

  /// `stopId|tripId` -> platform seen live and when; survives restarts via prefs.
  late final Map<String, ({String platform, DateTime at})> _seenPlatforms = _loadSeenPlatforms();

  Map<String, ({String platform, DateTime at})> _loadSeenPlatforms() {
    try {
      final raw = jsonDecode(_prefs.getString(_seenPlatformsKey) ?? '{}') as Map<String, dynamic>;
      return {
        for (final e in raw.entries)
          if (e.value case [String p, String at] when DateTime.tryParse(at) != null)
            e.key: (platform: p, at: DateTime.parse(at)),
      };
    } catch (_) {
      return {};
    }
  }

  /// Keeps the current station's platforms from a new snapshot, stamped with Renfe's own time,
  /// so a later restart knows how old each one is.
  void _rememberPlatforms(PlatformSnapshot snap, String stopId, DateTime now) {
    var changed = false;
    platformsAt(snap, stopId, now).forEach((trip, platform) {
      final key = '$stopId|$trip';
      final at = snap.byTrip[trip]!.at;
      final old = _seenPlatforms[key];
      if (old == null || old.platform != platform || old.at != at) {
        _seenPlatforms[key] = (platform: platform, at: at);
        changed = true;
      }
    });
    final before = _seenPlatforms.length;
    _seenPlatforms.removeWhere((_, v) => now.difference(v.at).abs() > rememberPlatformFor);
    if (changed || _seenPlatforms.length != before) {
      _prefs.setString(_seenPlatformsKey, jsonEncode({
        for (final e in _seenPlatforms.entries) e.key: [e.value.platform, e.value.at.toUtc().toIso8601String()],
      }));
    }
  }

  /// Live platforms at [stopId]: fresh ones from Renfe, else the last one seen recently.
  Map<String, String> _livePlatformsAt(String stopId, DateTime now) {
    final prefix = '$stopId|';
    return {
      for (final e in _seenPlatforms.entries)
        if (e.key.startsWith(prefix) && now.difference(e.value.at).abs() <= rememberPlatformFor)
          e.key.substring(prefix.length): e.value.platform,
      ...platformsAt(positions, stopId, now),
    };
  }

  /// Renfe service alerts, all of them; kept across failed downloads.
  List<RenfeAlert> _alerts = const [];
  tz.TZDateTime? _alertsAt;

  /// Alerts are not urgent: at most one download every this long, only in the foreground.
  static const alertsEvery = Duration(minutes: 5);

  /// Alerts in effect for the current station and the lines that call there.
  List<StationAlert> get stationAlerts {
    final s = station, b = board;
    if (s == null || b == null || _alerts.isEmpty) return const [];
    return alertsFor(_alerts, stopId: s.id, lines: b.lines, now: _clock().toUtc());
  }

  /// Fire and forget: a slow alerts feed never holds up the board.
  void _maybeFetchAlerts() {
    final client = _alertsClient, now = _clock(), last = _alertsAt;
    if (client == null || (last != null && !now.difference(last).isNegative && now.difference(last) < alertsEvery)) {
      return;
    }
    _alertsAt = now;
    unawaited(() async {
      try {
        _alerts = await client.fetch();
      } catch (_) {
        return; // keep the last ones
      }
      if (!_disposed) notifyListeners();
    }());
  }

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
    _saveVia(null);
    _setFilters(next);
  }

  void clearFilters() {
    _saveVia(null);
    _setFilters({});
  }

  /// Go to [stopId] (null clears it); destinations are dropped.
  void setVia(String? stopId) {
    _saveVia(stopId);
    _setFilters({});
  }

  void _saveVia(String? stopId) {
    via = stopId;
    final s = station;
    if (s == null) return;
    if (stopId == null) {
      _prefs.remove(_viaKey(s.id));
    } else {
      _prefs.setString(_viaKey(s.id), stopId);
    }
  }

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
    _timer = null;
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

  /// A reading from our server only covers its station: never let it stand for another one.
  void _forgetOtherStationLive(String stopId) {
    var forgot = false;
    if (_rtStop != null && _rtStop != stopId) {
      rt = null;
      _rtStop = null;
      forgot = true;
    }
    if (_positionsStop != null && _positionsStop != stopId) {
      positions = null;
      _positionsStop = null;
    }
    if (forgot && _timer != null && !_disposed) unawaited(_pollRt()); // don't wait 30 s without realtime
  }

  /// Realtime for the current station from our server; false if it can't answer (then Renfe).
  Future<bool> _pollLive() async {
    final client = _liveClient, s = station;
    if (client == null || s == null) return false;
    final StationLive live;
    try {
      live = await client.fetch(s.id);
    } catch (_) {
      return false;
    }
    if (_disposed) return true;
    if (station?.id != s.id) return true; // the user moved on: drop it, the new station polls itself
    rt = live.rt;
    _rtStop = s.id;
    final p = live.positions, last = positions;
    // Out-of-order guard across both sources (a station's own snapshot can lag Renfe's whole one).
    if (p != null && (last == null || !p.feedTimestamp.isBefore(last.feedTimestamp))) {
      positions = p;
      _positionsStop = s.id;
      _rememberPlatforms(p, s.id, _clock());
    }
    return true;
  }

  Future<void> _pollRt() async {
    _maybeFetchAlerts();
    if (await _pollLive()) {
      if (_disposed) return;
      rtAttempted = true;
      _recompute();
      return;
    }
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
          _rtStop = null;
        } catch (_) {
          // Board.rtStale reflects it.
        }
      }(),
      if (wantPositions)
        () async {
          try {
            final p = await _positionsClient.fetch();
            final last = positions;
            if (last == null || !p.feedTimestamp.isBefore(last.feedTimestamp)) {
              positions = p; // drop out-of-order answers
              _positionsStop = null;
              final s = station;
              if (s != null) _rememberPlatforms(p, s.id, _clock());
            }
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
      _forgetOtherStationLive(s.id);
      board = null; // never show (or hand the widget) the last station's trains under the new name
      filters = _savedFilters(s.id);
      via = _prefs.getString(_viaKey(s.id));
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
    if (b == null || feeds.length < s.nucleos.length) return;
    final v = via;
    if (v != null && !b.reachable.any((r) => r.$1 == v)) {
      _saveVia(null);
      _recompute();
    }
    if (filters.isEmpty) return;
    final all = b.destinations.toSet(); // computed before the filter is applied
    final kept = filters.where(all.contains).toSet();
    if (kept.length != filters.length) _setFilters(kept);
  }

  Board? _widgetBoard;
  bool _widgetBoardDirty = true;

  /// The board with [widgetTrains] trains for the home screen widget (same station, filters and
  /// stop); computed only when asked, once per change.
  Board? get widgetBoard {
    if (board == null) return null; // e.g. right after a station change
    if (_widgetBoardDirty) {
      final s = station;
      _widgetBoard = s == null
          ? null
          : computeBoard(feeds, s.id, _clock(), rt,
              destinations: filters,
              via: via,
              limit: widgetTrains,
              requiredNucleos: s.nucleos,
              livePlatforms: _livePlatformsAt(s.id, _clock()));
      _widgetBoardDirty = false;
    }
    return _widgetBoard;
  }

  void _recompute() {
    _widgetBoardDirty = true;
    final s = station;
    board = (s == null || (feeds.isEmpty && !_feedsSettled))
        ? null
        : computeBoard(feeds, s.id, _clock(), rt,
            destinations: filters,
            via: via,
            limit: limit,
            requiredNucleos: s.nucleos,
            livePlatforms: _livePlatformsAt(s.id, _clock()));
    if (!_disposed) notifyListeners();
  }
}
