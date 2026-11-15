import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/location.dart';

final feedBody = File('test/fixtures/feed.json').readAsStringSync();
final rtBody = File('test/fixtures/trip_updates.json').readAsStringSync();

http.Response okJson(String body, {Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

/// Serves the feed and RT fixtures; counts RT calls; can fail either.
class FakeServer {
  bool feedFails = false;
  bool rtFails = false;
  int rtCalls = 0;

  late final http.Client client = MockClient((req) async {
    if (req.url.host == 'gtfsrt.renfe.com') {
      rtCalls++;
      if (rtFails) throw const SocketException('offline');
      return okJson(rtBody);
    }
    if (feedFails) throw const SocketException('offline');
    return okJson(feedBody);
  });
}

/// Location whose answers the test releases by hand.
class FakeLocation implements LocationSource {
  final pending = <Completer<(double, double)?>>[];

  /// When set, answers immediately (e.g. before the feed download finishes).
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

/// Records periodic timers so tests can count the live ones.
class TimerLog {
  final timers = <FakeTimer>[];
  Timer create(Duration d, void Function(Timer) cb) => FakeTimer(cb)..register(this);
  int get active => timers.where((t) => t.isActive).length;
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
