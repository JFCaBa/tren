import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:http/testing.dart';
import 'package:proximotren/follow/follow_logic.dart';
import 'package:proximotren/follow/follower.dart';
import 'package:proximotren/location.dart';

final rtBody = File('test/fixtures/trip_updates.json').readAsStringSync();
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response okJson(String body, {Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

/// Serves index.json, `feeds/<id>.json` and the RT fixture. Each path can fail or be held back.
class FakeServer {
  bool feedFails = false; // every jfcaba.github.io request fails
  String? indexOverride; // served instead of fixtures/index.json
  String? feed40Override; // served instead of fixtures/feed_40.json
  final failing = <String>{}; // e.g. 'feeds/10.json'
  final holds = <String, Completer<void>>{}; // path -> gate
  String? positionsBody; // served at gtfsrt.renfe.com/vehicle_positions.json (404 when null)
  bool positionsFails = false;
  int positionsCalls = 0;
  String? alertsBody; // served at gtfsrt.renfe.com/alerts.json (404 when null)
  int alertsCalls = 0;
  bool rtFails = false;
  bool rtHangs = false;
  int rtCalls = 0;
  final requested = <String>[];

  void hold(String path) => holds[path] = Completer<void>();
  void release(String path) => holds.remove(path)?.complete();

  late final http.Client client = MockClient((req) async {
    if (req.url.host == 'gtfsrt.renfe.com' && req.url.path.endsWith('vehicle_positions.json')) {
      positionsCalls++;
      if (positionsFails) throw const SocketException('offline');
      final body = positionsBody;
      return body == null ? http.Response('not found', 404) : okJson(body);
    }
    if (req.url.host == 'gtfsrt.renfe.com' && req.url.path.endsWith('alerts.json')) {
      alertsCalls++;
      final body = alertsBody;
      return body == null ? http.Response('not found', 404) : okJson(body);
    }
    if (req.url.host == 'gtfsrt.renfe.com') {
      rtCalls++;
      if (rtHangs) return Completer<http.Response>().future;
      if (rtFails) throw const SocketException('offline');
      return okJson(rtBody);
    }
    final path = req.url.path.replaceFirst('/tren/', '');
    requested.add(path);
    final gate = holds[path];
    if (gate != null) await gate.future;
    if (feedFails || failing.contains(path)) throw const SocketException('offline');
    return switch (path) {
      'index.json' => okJson(indexOverride ?? fixture('index.json')),
      'feeds/40.json' => okJson(feed40Override ?? fixture('feed_40.json')),
      'feeds/10.json' => okJson(fixture('feed_10.json')),
      _ => http.Response('not found', 404),
    };
  });
}

/// Location whose answers the test releases by hand.
class FakeLocation implements LocationSource {
  final pending = <Completer<(double, double)?>>[];

  /// When set, answers immediately (e.g. before downloads finish).
  (double, double)? immediate;

  /// requestPermission flag of every call, in order.
  final requests = <bool>[];

  @override
  Future<(double, double)?> current({bool requestPermission = false}) {
    requests.add(requestPermission);
    if (immediate != null) return Future.value(immediate);
    final c = Completer<(double, double)?>();
    pending.add(c);
    return c.future;
  }

  void answer((double, double)? coords) {
    for (final c in pending) {
      if (!c.isCompleted) c.complete(coords);
    }
    pending.clear();
  }
}

const nearSilla = (39.3625, -0.4145);
const nearGandia = (38.9710, -0.1790);
const nearAtocha = (40.4067, -3.6893);
const nearShared = (41.0001, -1.0001);

/// Records periodic timers so tests can count the live ones.
class TimerLog {
  final timers = <FakeTimer>[];
  Timer create(Duration d, void Function(Timer) cb) => FakeTimer(cb)..register(this);
  int get active => timers.where((t) => t.isActive).length;
  void fireActive() {
    for (final t in [...timers]) {
      if (t.isActive) t.fire();
    }
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.cb);
  final void Function(Timer) cb;
  bool _active = true;
  void register(TimerLog log) => log.timers.add(this);
  void fire() => cb(this);
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

/// A vehicle_positions.json with one train at [stopId] showing [platform], stamped at [at].
String positionsJson(String tripId, String stopId, String platform, DateTime at) {
  final ts = at.millisecondsSinceEpoch ~/ 1000;
  return jsonEncode({
    'header': {'timestamp': '$ts'},
    'entity': [
      {
        'vehicle': {
          'trip': {'tripId': tripId},
          'currentStatus': 'INCOMING_AT',
          'timestamp': '$ts',
          'stopId': stopId,
          'vehicle': {'label': 'C2-12345-PLATF.($platform)'},
        },
      },
    ],
  });
}

/// feed_40.json with [n] Gandia trains at Silla every 5 min from 18:05 (T1… replaced).
String manyTrainsFeed(int n) {
  final d = jsonDecode(fixture('feed_40.json')) as Map<String, dynamic>;
  d['trips'] = [
    for (var i = 0; i < n; i++)
      {
        'id': 'M$i',
        'line': 'C1',
        'dest': 'Gandia',
        'dates': ['2026-11-15'],
        'times': [
          ['65000', 64800 + 300 * i],
          ['64200', 65100 + 300 * i],
          ['69110', 67800 + 300 * i],
        ],
      },
  ];
  return jsonEncode(d);
}


class FakeFollower extends ChangeNotifier implements Follower {
  FakeFollower({this.granted = true});
  bool granted;
  Exception? failure;
  @override
  FollowedTrain? current;

  @override
  Future<bool> follow(FollowedTrain t) async {
    if (failure != null) throw failure!;
    if (!granted) return false;
    current = t;
    notifyListeners();
    return true;
  }

  @override
  Future<void> stop() async {
    current = null;
    notifyListeners();
  }

  @override
  Future<void> sync() async {}

  int settingsOpened = 0;
  @override
  Future<void> openSettings() async => settingsOpened++;
}
