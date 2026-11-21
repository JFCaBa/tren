import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../domain/position.dart';
import 'follow_logic.dart';
import 'follow_loop.dart';
import 'live_activity.dart';
import 'follower.dart';
import 'push_token.dart';

const _key = 'push_follow';
const _timeout = Duration(seconds: 10);

/// POST /follow timeout: above the server's worst case (5 s waiting for a poll slot + 8 s Darwin
/// deadline) and within nginx's proxy_read_timeout (20 s). DELETE keeps [_timeout].
const followPostTimeout = Duration(seconds: 18);

/// iOS: the server follows the train and sends push alerts; the app only registers and unregisters.
class PushFollower extends ChangeNotifier implements Follower {
  PushFollower._(this._client, this._prefs, this._push, this._baseUrl, this._clock, this._postTimeout, this._activity) {
    _current = _saved()?.train;
    _activity?.tokens.listen(_onActivityToken);
  }

  /// Call once, before runApp. The saved follow shows at once; the refresh with the server runs in
  /// the background, so a slow network never delays the app's start.
  static Future<PushFollower> create({
    required http.Client client,
    required SharedPreferences prefs,
    required PushToken push,
    String baseUrl = apiBaseUrl,
    DateTime Function() clock = DateTime.now,
    @visibleForTesting Duration postTimeout = followPostTimeout,
    LiveActivity? activity,
  }) async {
    final f = PushFollower._(client, prefs, push, baseUrl, clock, postTimeout, activity);
    unawaited(f.sync());
    return f;
  }

  final http.Client _client;
  final SharedPreferences _prefs;
  final PushToken _push;
  final String _baseUrl;
  final DateTime Function() _clock;
  final Duration _postTimeout;

  /// iOS 16.1+: the lock-screen view of the followed train, fed by the server through its token.
  final LiveActivity? _activity;

  /// The follow generation the running Live Activity was started for: its tokens belong to it.
  int _activityGen = -1;

  FollowedTrain? _current;
  Future<void> _queue = Future.value();

  /// Bumped by every follow() and stop(): an operation that sees a newer value was superseded and
  /// must not change the state.
  int _gen = 0;

  /// What the server last accepted (a POST answered 200) or may have accepted (a POST that timed
  /// out or failed on the network), even from a superseded operation, until that token is
  /// deleted: so a stop or a later follow can always clean it up.
  _Saved? _registered;

  @override
  FollowedTrain? get current => _current;

  /// One operation at a time, so the server sees requests in the order they were made and the
  /// saved state only changes inside the queue.
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _queue.then((_) => f());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  @override
  Future<bool> follow(FollowedTrain t) {
    final gen = ++_gen;
    return _serial(() async {
      if (gen != _gen) return true; // a later follow or stop already replaced this one
      if (!await _push.requestPermission()) return false;
      final token = await _push.token();
      // Allowed, but the device couldn't register: not something Settings can fix.
      if (token == null) throw const FollowFailed(FollowFailure.network);
      final env = await _push.environment();
      if (gen != _gen) return true;
      final old = _saved();
      if (old != null && old.token != token) {
        // Token rotated: the old registration and the train shown for it are gone either way.
        await _delete(old.token);
        await _clear();
      }
      final stray = _registered;
      if (stray != null && stray.token != token) await _delete(stray.token);
      final s = _Saved(t, _clock().millisecondsSinceEpoch, token, env);
      final code = await _post(s);
      if (gen != _gen) return true;
      if (code == 200) {
        await _save(s);
        if (gen != _gen) return true;
        _set(t);
        await _startActivity(t, gen);
        return true;
      }
      await _dropStray();
      throw FollowFailed(code == 410 ? FollowFailure.gone : FollowFailure.network);
    });
  }

  @override
  Future<void> stop() {
    ++_gen;
    // Forget the follow on disk right away: if iOS kills the app while the queue waits, a relaunch
    // must not bring it back.
    final saved = _saved()?.token;
    final removed = _prefs.remove(_key);
    _set(null);
    _endActivity();
    return _serial(() async {
      await removed;
      // _registered is read here, once any earlier POST has answered.
      final tokens = {?saved, ?_saved()?.token, ?_registered?.token};
      await _prefs.remove(_key); // again: a pending follow's save may have rewritten it
      for (final t in tokens) {
        await _delete(t);
      }
    });
  }

  @override
  Future<void> sync() {
    final gen = _gen;
    return _serial(() async {
      if (gen != _gen) return;
      final s = _saved();
      if (s == null) return _set(null);
      _set(s.train);
      final started = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      if (!_clock().isBefore(started.add(followMaxDuration))) {
        await _clear();
        await _delete(s.token);
        return;
      }
      final token = await _push.token();
      if (token == null || gen != _gen) return; // can't refresh now: keep the follow
      final env = await _push.environment();
      if (gen != _gen) return;
      if (token != s.token) await _delete(s.token);
      final fresh = _Saved(s.train, s.startedAt, token, env, s.activity);
      final code = await _post(fresh);
      if (gen != _gen) return;
      if (code == 410) return _clear();
      if (token != s.token || env != s.env) await _save(fresh);
    });
  }

  @override
  Future<void> openSettings() => _push.openSettings();

  /// After a failed follow: the server may still hold a registration (from a superseded follow, or
  /// a POST without an answer) that no saved state accounts for. Delete it when its token differs
  /// from the saved follow's. With the same token the saved follow stays: deleting would end it on
  /// the server too (and offline the DELETE may not get there). `_registered` keeps the token, so a
  /// later stop() still deletes it, and the next sync() re-posts the saved follow.
  Future<void> _dropStray() async {
    final stray = _registered;
    if (stray == null || stray.token == _saved()?.token) return;
    await _delete(stray.token);
  }

  /// POST /follow; the HTTP status, or null on a timeout or network error. Without a definite
  /// answer the server may still have registered it, so it counts as registered; a definite
  /// non-200 answer does not.
  Future<int?> _post(_Saved s) async {
    try {
      final r = await _client
          .post(Uri.parse('$_baseUrl/follow'), headers: _headers, body: jsonEncode(s.body()))
          .timeout(_postTimeout);
      if (r.statusCode == 200) _registered = s;
      return r.statusCode;
    } catch (_) {
      _registered = s;
      return null;
    }
  }

  /// Best-effort DELETE /follow: the server also ends follows on its own after 3 h. `_registered`
  /// is forgotten only once the server answered 2xx, so a failed DELETE is retried by a later stop.
  Future<void> _delete(String token) async {
    try {
      final r = await _client
          .delete(Uri.parse('$_baseUrl/follow'), headers: _headers, body: jsonEncode({'token': token}))
          .timeout(_timeout);
      if (r.statusCode >= 200 && r.statusCode < 300 && _registered?.token == token) _registered = null;
    } catch (_) {}
  }

  static const _headers = {'User-Agent': userAgent, 'Content-Type': 'application/json'};

  _Saved? _saved() {
    final j = _prefs.getString(_key);
    if (j == null) return null;
    try {
      return _Saved.fromJson(jsonDecode(j) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(_Saved s) => _prefs.setString(_key, jsonEncode(s.toJson()));

  Future<void> _clear() async {
    await _prefs.remove(_key);
    _set(null);
    _endActivity();
  }

  Future<void> _startActivity(FollowedTrain t, int gen) async {
    final a = _activity;
    if (a == null) return;
    // Set before start: iOS may hand over the first push token before start() answers.
    _activityGen = gen;
    var started = false;
    try {
      final first = contentState(scheduled: t.scheduled, canceled: false, usualPlatform: t.usualPlatform);
      started = await a.start(t, first);
    } catch (_) {
      // no Live Activity: alerts still come
    }
    if (started && gen == _gen) return;
    if (_activityGen == gen) _activityGen = -1;
    // Started for a follow stopped meanwhile (a newer follow's start runs after this one, in the
    // queue), or not started: then the previous train's activity must not linger either.
    if (started || gen == _gen) unawaited(a.end().catchError((_) {}));
  }

  void _endActivity() {
    _activityGen = -1;
    unawaited(_activity?.end().catchError((_) {}));
  }

  /// iOS gave the running activity a (new) push token: tell the server, for the same follow.
  void _onActivityToken(String token) {
    final gen = _gen;
    if (gen != _activityGen) return; // for a follow that was stopped or replaced
    unawaited(_serial(() async {
      if (gen != _gen || gen != _activityGen) return;
      final s = _saved();
      if (s == null || s.activity == token) return;
      final fresh = s.withActivity(token);
      // Kept even if the POST fails: the next sync() posts it again.
      await _save(fresh);
      final code = await _post(fresh);
      if (gen != _gen) return;
      if (code == 410) await _clear();
    }).catchError((_) {}));
  }

  void _set(FollowedTrain? t) {
    if (t == _current) return;
    _current = t;
    notifyListeners();
  }
}

class _Saved {
  const _Saved(this.train, this.startedAt, this.token, this.env, [this.activity]);
  final FollowedTrain train;
  final int startedAt; // epoch ms
  final String token;
  final String env;

  /// The Live Activity's push token, once iOS gave one.
  final String? activity;

  _Saved withActivity(String a) => _Saved(train, startedAt, token, env, a);

  factory _Saved.fromJson(Map<String, dynamic> j) => _Saved(FollowedTrain.fromJson(j['train'] as Map<String, dynamic>),
      j['startedAt'] as int, j['token'] as String, j['env'] as String, j['activity'] as String?);

  Map<String, dynamic> toJson() =>
      {'train': train.toJson(), 'startedAt': startedAt, 'token': token, 'env': env, 'activity': ?activity};

  Map<String, dynamic> body() =>
      {'token': token, 'env': env, ...train.toJson(), 'startedAt': startedAt, 'activityToken': ?activity};

  @override
  bool operator ==(Object other) =>
      other is _Saved &&
      other.train == train &&
      other.startedAt == startedAt &&
      other.token == token &&
      other.env == env &&
      other.activity == activity;

  @override
  int get hashCode => Object.hash(train, startedAt, token, env, activity);
}
