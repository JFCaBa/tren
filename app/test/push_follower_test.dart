import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/config.dart';
import 'package:proximotren/follow/follow_logic.dart';
import 'package:proximotren/follow/follower.dart';
import 'package:proximotren/follow/live_activity.dart';
import 'package:proximotren/follow/push_follower.dart';
import 'package:proximotren/follow/push_token.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

class FakePushToken implements PushToken {
  bool granted = true;
  String? current = 'abc123';
  String env = 'sandbox';

  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<String?> token() async => current;
  @override
  Future<String> environment() async => env;

  int settingsOpened = 0;
  @override
  Future<void> openSettings() async => settingsOpened++;
}

Matcher failed(FollowFailure r) => isA<FollowFailed>().having((e) => e.reason, 'reason', r);

/// Real prefs whose setString can be held, to land a stop() while a save is pending.
class GatedPrefs implements SharedPreferences {
  GatedPrefs(this._real);
  final SharedPreferences _real;
  Completer<void>? hold;
  bool saving = false;

  @override
  String? getString(String key) => _real.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    saving = true;
    final h = hold;
    if (h != null) await h.future;
    saving = false;
    return _real.setString(key, value);
  }

  @override
  Future<bool> remove(String key) => _real.remove(key);

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeLiveActivity implements LiveActivity {
  bool supported = true;
  String? tokenDuringStart;
  final started = <(FollowedTrain, Map<String, Object?>)>[];
  int ended = 0;
  final _tokens = StreamController<String>.broadcast(sync: true);
  void give(String token) => _tokens.add(token);

  @override
  Future<bool> start(FollowedTrain t, Map<String, Object?> state) async {
    started.add((t, state));
    final early = tokenDuringStart;
    if (early != null) give(early);
    return supported;
  }

  @override
  Future<void> update(Map<String, Object?> state) async {}

  @override
  Future<void> end() async => ended++;

  @override
  Stream<String> get tokens => _tokens.stream;
}

class Call {
  Call(this.method, this.body);
  final String method;
  final Map<String, dynamic> body;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  final train = FollowedTrain(
      tripId: 'T30', stopId: '18000', scheduled: DateTime.utc(2026, 11, 17, 9, 30), title: '10:30 a Guadalajara',
      usualPlatform: '2', route: const [('10000', 'Chamartín'), ('18000', 'Atocha')]);
  final other = FollowedTrain(
      tripId: 'T40', stopId: '18000', scheduled: DateTime.utc(2026, 11, 17, 9, 40), title: '10:40 a Alcalá',
      route: const [('18000', 'Atocha')]);
  late DateTime now;
  late FakePushToken push;
  late List<Call> calls;
  late List<http.Request> requests;
  // Answers for POSTs, in order; when empty, 200. An int is a status, a Completer delays the answer.
  late List<Object> postAnswers;
  late bool deleteFails;
  late SharedPreferences prefs;

  setUp(() async {
    now = DateTime.utc(2026, 11, 17, 9, 0);
    push = FakePushToken();
    calls = [];
    requests = [];
    postAnswers = [];
    deleteFails = false;
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  late final client = MockClient((req) async {
    requests.add(req);
    calls.add(Call(req.method, jsonDecode(req.body) as Map<String, dynamic>));
    if (req.method == 'DELETE') {
      if (deleteFails) throw const SocketException('offline');
      return http.Response('', 204);
    }
    Object a = postAnswers.isEmpty ? 200 : postAnswers.removeAt(0);
    if (a is Completer<Object>) a = await a.future;
    if (a is Exception) throw a;
    final code = a as int;
    return http.Response(
        code == 200 ? '{"ok":true}' : code == 410 ? '{"error":"gone"}' : '{"error":"x"}', code);
  });

  Future<PushFollower> make(
      {SharedPreferences? store, Duration postTimeout = followPostTimeout, LiveActivity? activity}) async {
    final f = await PushFollower.create(
        client: client,
        prefs: store ?? prefs,
        push: push,
        clock: () => now,
        postTimeout: postTimeout,
        activity: activity);
    await pumpEventQueue(); // let create's sync finish
    return f;
  }

  Map<String, dynamic>? saved() {
    final s = prefs.getString('push_follow');
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  void save(FollowedTrain t, DateTime startedAt, {String token = 'abc123', String env = 'sandbox'}) =>
      prefs.setString('push_follow',
          jsonEncode({'train': t.toJson(), 'startedAt': startedAt.millisecondsSinceEpoch, 'token': token, 'env': env}));

  test('follow posts token env and train', () async {
    final f = await make();
    var notified = 0;
    f.addListener(() => notified++);
    expect(await f.follow(train), isTrue);
    expect(calls.single.method, 'POST');
    expect(calls.single.body, {
      'token': 'abc123',
      'env': 'sandbox',
      ...train.toJson(),
      'startedAt': now.millisecondsSinceEpoch,
    });
    final r = requests.single;
    expect(r.url.toString(), '$apiBaseUrl/follow');
    expect(r.headers['User-Agent'], userAgent);
    expect(r.headers['Content-Type'], startsWith('application/json'));
    expect(f.current, train);
    expect(notified, 1);
    expect(saved(), {
      'train': train.toJson(),
      'startedAt': now.millisecondsSinceEpoch,
      'token': 'abc123',
      'env': 'sandbox',
    });
  });

  test('follow omits a null usual platform', () async {
    final f = await make();
    await f.follow(other);
    expect(calls.single.body.containsKey('usual'), isFalse);
  });

  test('permission denied follows nothing', () async {
    push.granted = false;
    final f = await make();
    expect(await f.follow(train), isFalse);
    expect(calls, isEmpty);
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  test('openSettings goes through the push channel', () async {
    final f = await make();
    await f.openSettings();
    expect(push.settingsOpened, 1);
  });

  test('no token with permission throws network', () async {
    push.current = null;
    final f = await make();
    await expectLater(f.follow(train), throwsA(failed(FollowFailure.network)));
    expect(calls, isEmpty);
    expect(f.current, isNull);
  });

  test('410 throws gone and saves nothing', () async {
    postAnswers = [410];
    final f = await make();
    await expectLater(f.follow(train), throwsA(failed(FollowFailure.gone)));
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  test('other errors throw network', () async {
    postAnswers = [409, 503, const SocketException('offline')];
    final f = await make();
    for (var i = 0; i < 3; i++) {
      await expectLater(f.follow(train), throwsA(failed(FollowFailure.network)));
    }
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  test('stop clears even if DELETE fails', () async {
    final f = await make();
    await f.follow(train);
    deleteFails = true;
    var notified = 0;
    f.addListener(() => notified++);
    await f.stop();
    expect(f.current, isNull);
    expect(notified, 1);
    expect(saved(), isNull);
    expect(calls.last.method, 'DELETE');
    expect(calls.last.body, {'token': 'abc123'});
  });

  test('sync re-posts within 3 h and keeps on 200', () async {
    final f = await make();
    await f.follow(train);
    now = now.add(const Duration(hours: 2, minutes: 59));
    await f.sync();
    expect(calls.map((c) => c.method), ['POST', 'POST']);
    expect(f.current, train);
    expect(saved(), isNotNull);
  });

  test('sync clears on 410', () async {
    final f = await make();
    await f.follow(train);
    postAnswers = [410];
    var notified = 0;
    f.addListener(() => notified++);
    await f.sync();
    expect(f.current, isNull);
    expect(notified, 1);
    expect(saved(), isNull);
  });

  test('sync clears after 3 h and sends DELETE', () async {
    final f = await make();
    await f.follow(train);
    now = now.add(const Duration(hours: 3));
    await f.sync();
    expect(f.current, isNull);
    expect(saved(), isNull);
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
  });

  test('sync keeps on network error', () async {
    final f = await make();
    await f.follow(train);
    postAnswers = [const SocketException('offline'), 503, 429];
    for (var i = 0; i < 3; i++) {
      await f.sync();
    }
    expect(f.current, train);
    expect(saved(), isNotNull);
  });

  test('sync posts original startedAt', () async {
    final started = now;
    final f = await make();
    await f.follow(train);
    now = now.add(const Duration(hours: 1));
    await f.sync();
    expect(calls.last.body['startedAt'], started.millisecondsSinceEpoch);
  });

  test('stop during pending sync wins', () async {
    final f = await make();
    await f.follow(train);
    final gate = Completer<Object>();
    postAnswers = [gate];
    final syncing = f.sync();
    await Future<void>.delayed(Duration.zero);
    final stopping = f.stop();
    expect(f.current, isNull);
    gate.complete(200);
    await syncing;
    await stopping;
    expect(f.current, isNull);
    expect(saved(), isNull);
    expect(calls.map((c) => c.method), ['POST', 'POST', 'DELETE']); // the DELETE goes after the POST
  });

  test('second follow wins over first', () async {
    final f = await make();
    final gate = Completer<Object>();
    postAnswers = [gate];
    final first = f.follow(train);
    await Future<void>.delayed(Duration.zero);
    final second = f.follow(other);
    gate.complete(200);
    await first;
    expect(await second, isTrue);
    expect(f.current, other);
    expect(FollowedTrain.fromJson(saved()!['train'] as Map<String, dynamic>), other);
    expect(calls.map((c) => c.body['tripId']), ['T30', 'T40']);
  });

  test('token rotation deletes old registration', () async {
    save(train, now, token: 'old');
    push.current = 'new';
    final f = await make();
    expect(calls.map((c) => c.method), ['DELETE', 'POST']);
    expect(calls[0].body, {'token': 'old'});
    expect(calls[1].body['token'], 'new');
    expect(f.current, train);
    expect(saved()!['token'], 'new');

    // Following again with yet another token also deletes the previous one.
    push.current = 'newer';
    await f.follow(other);
    expect(calls.map((c) => c.method), ['DELETE', 'POST', 'DELETE', 'POST']);
    expect(calls[2].body, {'token': 'new'});
    expect(calls[3].body['token'], 'newer');
  });

  test('create calls sync', () async {
    save(train, now.subtract(const Duration(minutes: 10)));
    final gate = Completer<Object>();
    postAnswers = [gate];
    final f = await PushFollower.create(client: client, prefs: prefs, push: push, clock: () => now);
    expect(f.current, train); // shown before the server answers
    await pumpEventQueue();
    gate.complete(200);
    await pumpEventQueue();
    expect(f.current, train);
    expect(calls.single.method, 'POST');
    expect(calls.single.body['startedAt'], now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch);
  });

  test('create with nothing saved sends nothing', () async {
    final f = await make();
    expect(f.current, isNull);
    expect(calls, isEmpty);
  });

  test('stop during pending first follow (nothing saved) sends DELETE after the POST', () async {
    final f = await make();
    final gate = Completer<Object>();
    postAnswers = [gate];
    final following = f.follow(train);
    await pumpEventQueue();
    final stopping = f.stop();
    gate.complete(200);
    await following;
    await stopping;
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  test("superseded follow's 200 is never saved after stop", () async {
    final f = await make();
    final gate = Completer<Object>();
    postAnswers = [gate];
    final seen = <FollowedTrain?>[];
    f.addListener(() => seen.add(f.current));
    final following = f.follow(train);
    await pumpEventQueue();
    final stopping = f.stop();
    gate.complete(200);
    await following;
    await stopping;
    await f.sync();
    expect(seen, isNot(contains(train)));
    expect(saved(), isNull);
    expect(f.current, isNull);
  });

  test('superseded follow then failing follow sends DELETE of the stray registration', () async {
    final f = await make();
    final gate = Completer<Object>();
    postAnswers = [gate, 410];
    final first = f.follow(train);
    await pumpEventQueue();
    final second = f.follow(other);
    gate.complete(200); // the server now holds the first train, which nothing saved
    await first;
    await expectLater(second, throwsA(failed(FollowFailure.gone)));
    expect(calls.map((c) => c.method), ['POST', 'POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
    expect(f.current, isNull);
    expect(saved(), isNull);

    // Nothing stray is left for a later stop to delete again.
    await f.stop();
    expect(calls.map((c) => c.method), ['POST', 'POST', 'DELETE']);
  });

  test('stop arriving while the follow save is pending: nothing shown or persisted', () async {
    final gated = GatedPrefs(prefs)..hold = Completer<void>();
    final f = await make(store: gated);
    final seen = <FollowedTrain?>[];
    f.addListener(() => seen.add(f.current));
    final following = f.follow(train);
    while (!gated.saving) {
      await Future<void>.delayed(Duration.zero);
    }
    final stopping = f.stop();
    gated.hold!.complete();
    await following;
    await stopping;
    expect(seen, isNot(contains(train)));
    expect(f.current, isNull);
    expect(saved(), isNull);
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
  });

  test('token rotation then failed POST leaves no stale follow', () async {
    save(train, now, token: 'old');
    push.current = 'old';
    final f = await make(); // sync re-posts with the same token
    expect(f.current, train);
    push.current = 'new';
    postAnswers = [503];
    await expectLater(f.follow(other), throwsA(failed(FollowFailure.network)));
    expect(calls.map((c) => c.method), ['POST', 'DELETE', 'POST']);
    expect(calls[1].body, {'token': 'old'});
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  group('ChannelPushToken with no native side', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const p = ChannelPushToken();

    test('fails quietly', () async {
      expect(await p.requestPermission(), isFalse);
      expect(await p.token(), isNull);
      expect(await p.environment(), 'production');
      await p.openSettings();
    });
  });

  test('stop clears the saved follow at once, before the queue drains', () async {
    final f = await make();
    await f.follow(train);
    final gate = Completer<Object>();
    postAnswers = [gate];
    final following = f.follow(other); // POST held; the first train is still saved
    await pumpEventQueue();
    final stopping = f.stop();
    expect(prefs.getString('push_follow'), isNull); // as if iOS killed the app now
    expect(f.current, isNull);
    gate.complete(200);
    await following;
    await stopping;
    expect(saved(), isNull);
    expect(calls.map((c) => c.method), ['POST', 'POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
  });

  test('stop with a pending sync deletes both the saved and the new registration', () async {
    save(train, now, token: 'old');
    push.current = 'new';
    final gate = Completer<Object>();
    postAnswers = [gate];
    final f = await PushFollower.create(client: client, prefs: prefs, push: push, clock: () => now);
    await pumpEventQueue(); // sync: DELETE old, POST new (held)
    final stopping = f.stop();
    expect(prefs.getString('push_follow'), isNull);
    gate.complete(200);
    await stopping;
    expect(saved(), isNull);
    expect(f.current, isNull);
    final deletes = calls.where((c) => c.method == 'DELETE').map((c) => c.body['token']);
    expect(deletes, containsAll(['old', 'new']));
    expect(calls.last.method, 'DELETE');
  });

  test('POST timeout is above the server worst case and within nginx', () {
    // Server: up to 5 s waiting for a poll slot + 8 s Darwin deadline; nginx proxy_read_timeout 20 s.
    expect(followPostTimeout, const Duration(seconds: 18));
  });

  test('stop during a follow whose POST times out sends DELETE for that token', () async {
    final f = await make(postTimeout: const Duration(milliseconds: 50));
    postAnswers = [Completer<Object>()]; // never answers
    final following = f.follow(train);
    await pumpEventQueue();
    final stopping = f.stop();
    await following;
    await stopping;
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
    expect(f.current, isNull);
    expect(saved(), isNull);
  });

  test('a follow whose POST times out throws network and cleans up the attempted token', () async {
    final f = await make(postTimeout: const Duration(milliseconds: 50));
    postAnswers = [Completer<Object>()];
    await expectLater(f.follow(train), throwsA(failed(FollowFailure.network)));
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
    await f.stop(); // already cleaned up: nothing sent again
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
  });

  test('a follow whose POST fails on the network cleans up the attempted token', () async {
    final f = await make();
    postAnswers = [const SocketException('offline')];
    await expectLater(f.follow(train), throwsA(failed(FollowFailure.network)));
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
  });

  test('a definite non-200 answer leaves nothing to delete', () async {
    for (final code in [400, 409, 410, 429, 502, 503]) {
      calls.clear();
      final f = await make();
      postAnswers = [code];
      await expectLater(f.follow(train), throwsA(isA<FollowFailed>()));
      await f.stop();
      expect(calls.map((c) => c.method), ['POST'], reason: '$code');
    }
  });

  for (final failure in <String, Object Function()>{
    'times out': () => Completer<Object>(),
    'fails on the network': () => const SocketException('offline'),
  }.entries) {
    test('saved A, follow B ${failure.key}: A stays, a later stop deletes the token', () async {
      final f = await make(postTimeout: const Duration(milliseconds: 50));
      await f.follow(train);
      postAnswers = [failure.value()];
      await expectLater(f.follow(other), throwsA(failed(FollowFailure.network)));
      expect(f.current, train);
      expect(saved()?['train'], train.toJson());
      expect(calls.map((c) => c.method), ['POST', 'POST']); // no cleanup DELETE
      await f.stop();
      expect(calls.map((c) => c.method), ['POST', 'POST', 'DELETE']);
      expect(calls.last.body, {'token': 'abc123'});
    });
  }

  test('a DELETE that fails is retried by the next stop', () async {
    final f = await make();
    await f.follow(train);
    deleteFails = true;
    await f.stop();
    deleteFails = false;
    await f.stop();
    expect(calls.map((c) => c.method), ['POST', 'DELETE', 'DELETE']);
    expect(calls.last.body, {'token': 'abc123'});
    await f.stop(); // answered 204: nothing left to delete
    expect(calls.map((c) => c.method), ['POST', 'DELETE', 'DELETE']);
  });

  group('Live Activity', () {
    late FakeLiveActivity act;
    setUp(() => act = FakeLiveActivity());
    final tokenA = 'aa' * 32, tokenB = 'bb' * 32;

    test('starts after the follow is accepted, with a first state', () async {
      final f = await make(activity: act);
      expect(await f.follow(train), isTrue);
      expect(act.started.single.$1, train);
      expect(act.started.single.$2['status'], '');
      expect(act.started.single.$2['cancelled'], false);
      expect(calls.single.body.containsKey('activityToken'), isFalse);
    });

    test('a late token is posted with the same startedAt and saved', () async {
      final f = await make(activity: act);
      await f.follow(train);
      now = now.add(const Duration(seconds: 5));
      act.give(tokenA);
      await pumpEventQueue();
      expect(calls.length, 2);
      expect(calls[1].body['activityToken'], tokenA);
      expect(calls[1].body['startedAt'], calls[0].body['startedAt']);
      expect(saved()!['activity'], tokenA);
      // sync re-posts it
      calls.clear();
      await f.sync();
      expect(calls.single.body['activityToken'], tokenA);
    });

    test('stop ends it, and a token arriving after stop posts nothing', () async {
      final f = await make(activity: act);
      await f.follow(train);
      await f.stop();
      expect(act.ended, 1);
      calls.clear();
      act.give(tokenB);
      await pumpEventQueue();
      expect(calls.where((c) => c.method == 'POST'), isEmpty);
    });

    test('a token for a superseded follow posts nothing', () async {
      final f = await make(activity: act);
      await f.follow(train);
      act.give(tokenA);
      await pumpEventQueue();
      await f.follow(other);
      calls.clear();
      act.give(tokenB);
      await pumpEventQueue();
      expect(calls.single.body['tripId'], 'T40'); // posted for the current train, not the old one
      expect(calls.single.body['activityToken'], tokenB);
    });

    test('unsupported: following still works', () async {
      act.supported = false;
      final f = await make(activity: act);
      expect(await f.follow(train), isTrue);
      expect(f.current, train);
    });

    test('a failed follow starts nothing', () async {
      postAnswers = [410];
      final f = await make(activity: act);
      await expectLater(f.follow(train), throwsA(failed(FollowFailure.gone)));
      expect(act.started, isEmpty);
    });
  
    test('a token given before start answers is not lost', () async {
      act.tokenDuringStart = tokenA;
      final f = await make(activity: act);
      await f.follow(train);
      await pumpEventQueue();
      expect(calls.last.body['activityToken'], tokenA);
    });

    test('unsupported start ends any previous activity', () async {
      act.supported = false;
      final f = await make(activity: act);
      await f.follow(train);
      expect(act.ended, 1);
    });

    test('a token whose POST fails is kept and re-posted by sync', () async {
      final f = await make(activity: act);
      await f.follow(train);
      postAnswers = [const SocketException('offline')];
      act.give(tokenA);
      await pumpEventQueue();
      expect(saved()!['activity'], tokenA);
      calls.clear();
      await f.sync();
      expect(calls.single.body['activityToken'], tokenA);
    });
  });
}
