import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/data/feed.dart';
import 'package:proximotren/data/json_cache.dart';
import 'package:proximotren/data/nucleo_index.dart';

final feedBody = File('test/fixtures/feed_40.json').readAsStringSync();
final indexBody = File('test/fixtures/index.json').readAsStringSync();

/// UTF-8 response, as GitHub Pages serves it (plain http.Response defaults to latin1).
http.Response ok(String body, {Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

void main() {
  late Directory dir;
  late List<http.Request> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feedrepo');
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  MockClient serve(http.Response Function(http.Request) handler) => MockClient((req) async {
        requests.add(req);
        return handler(req);
      });

  test('downloads when no cache', () async {
    final repo = nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40');
    expect(await repo.loadCached(), isNull);
    final feed = await repo.refresh();
    expect(feed.trips.length, 3);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
    expect((await repo.loadCached())!.trips.length, 3);
  });

  test('sends etag and keeps cache on 304', () async {
    await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40').refresh();
    final repo = nucleoCache(serve((_) => http.Response('', 304)), dir, '40');
    final cached = await repo.loadCached();
    final feed = await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
    expect(identical(feed, cached), isTrue);
  });

  test('replaces cache on 200 with new etag', () async {
    await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40').refresh();
    final newer = feedBody.replaceFirst('2026-11-22', '2026-11-23');
    await nucleoCache(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir, '40').refresh();
    final repo = nucleoCache(serve((_) => http.Response('', 304)), dir, '40');
    expect((await repo.loadCached())!.validTo, '2026-11-23');
    await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"b"');
  });

  test('falls back to cache on network error', () async {
    await nucleoCache(serve((_) => ok(feedBody)), dir, '40').refresh();
    final repo = nucleoCache(MockClient((_) async => throw const SocketException('offline')), dir, '40');
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
  });

  test('test_first_launch_offline_reports_error', () async {
    final repo = nucleoCache(MockClient((_) async => throw const SocketException('offline')), dir, '40');
    expect(await repo.loadCached(), isNull);
    await expectLater(repo.refresh(), throwsA(isA<DataUnavailable>()));
  });

  test('timeout without cache throws DataUnavailable', () async {
    final never = Completer<http.Response>();
    final repo = nucleoCache(MockClient((_) => never.future), dir, '40',
        timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(milliseconds: 50));
    await expectLater(repo.refresh(), throwsA(isA<DataUnavailable>()));
  });

  test('first download gets a longer timeout than a refresh', () async {
    MockClient slow() => MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return ok(feedBody);
        });
    final first = nucleoCache(slow(), dir, '40', timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(seconds: 2));
    expect((await first.refresh()).nucleo, '40'); // no cache: waits up to firstTimeout
    final again = nucleoCache(slow(), dir, '40', timeout: const Duration(milliseconds: 50), firstTimeout: const Duration(seconds: 2));
    final cached = await again.loadCached();
    expect(await again.refresh(), same(cached)); // has cache: short timeout, falls back
  });

  test('default first-download timeout is 45 s', () {
    expect(nucleoCache(MockClient((_) async => http.Response('', 500)), dir, '40').firstTimeout,
        const Duration(seconds: 45));
  });

  test('index cache keeps the short first timeout', () {
    expect(indexCache(MockClient((_) async => http.Response('', 500)), dir).firstTimeout, const Duration(seconds: 15));
  });

  test('default timeout is 15 s', () {
    expect(nucleoCache(MockClient((_) async => http.Response('', 500)), dir, '40').timeout, const Duration(seconds: 15));
  });

  test('corrupt cache treated as missing', () async {
    File('${dir.path}/feed_40.json').writeAsStringSync('{"version":1,"trips":[');
    final repo = nucleoCache(serve((_) => ok(feedBody)), dir, '40');
    expect(await repo.loadCached(), isNull);
    expect((await repo.refresh()).trips.length, 3);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
  });

  test('etag sent belongs to the feed this repository holds', () async {
    await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40').refresh();
    final stale = nucleoCache(serve((_) => http.Response('', 304)), dir, '40');
    await stale.loadCached(); // holds feed "a"
    final newer = feedBody.replaceFirst('2026-11-22', '2026-11-23');
    await nucleoCache(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir, '40').refresh();
    await stale.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('refresh without loadCached still uses disk cache', () async {
    await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40').refresh();
    final repo = nucleoCache(serve((_) => http.Response('', 304)), dir, '40');
    expect((await repo.refresh()).trips.length, 3);
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('concurrent refresh shares one request', () async {
    final gate = Completer<void>();
    final repo = nucleoCache(MockClient((req) async {
      requests.add(req);
      await gate.future;
      return ok(feedBody);
    }), dir, '40');
    final a = repo.refresh(), b = repo.refresh();
    gate.complete();
    expect(identical(await a, await b), isTrue);
    expect(requests.length, 1);
  });

  test('write failure still returns downloaded feed', () async {
    final notADir = File('${dir.path}/file')..writeAsStringSync('x');
    final repo = nucleoCache(serve((_) => ok(feedBody)), Directory(notADir.path), '40');
    expect((await repo.refresh()).trips.length, 3);
  });

  test('concurrent loadCached share one read', () async {
    await nucleoCache(serve((_) => ok(feedBody)), dir, '40').refresh();
    final repo = nucleoCache(serve((_) => http.Response('', 304)), dir, '40');
    final a = repo.loadCached(), b = repo.loadCached();
    expect(await a, isNotNull);
    expect(await b, isNotNull);
  });

  test('absolute or leading-slash feed paths resolve against the base', () async {
    await nucleoCache(serve((_) => ok(feedBody)), dir, '40', path: '/tren/feeds/40.json').refresh();
    expect(requests.last.url.toString(), 'https://jfcaba.github.io/tren/feeds/40.json');
  });

  test('uses the feed path from the index when given', () async {
    await nucleoCache(serve((_) => ok(feedBody)), dir, '40', path: 'feeds/v3/40.json').refresh();
    expect(requests.single.url.toString(), 'https://jfcaba.github.io/tren/feeds/v3/40.json');
  });

  test('requests the nucleo url', () async {
    await nucleoCache(serve((_) => ok(feedBody)), dir, '40').refresh();
    expect(requests.single.url.toString(), 'https://jfcaba.github.io/tren/feeds/40.json');
  });

  test('index cache uses its own files', () async {
    final feed = await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"f"'})), dir, '40').refresh();
    final index = await indexCache(serve((_) => ok(indexBody, headers: {'etag': '"i"'})), dir).refresh();
    expect(requests.last.url.toString(), 'https://jfcaba.github.io/tren/index.json');
    expect(index, isA<NucleoIndex>());
    expect(feed, isA<Feed>());
    expect((await indexCache(serve((_) => http.Response('', 304)), dir).loadCached())!.nucleos.length, 2);
    expect((await nucleoCache(serve((_) => http.Response('', 304)), dir, '40').loadCached())!.nucleo, '40');
  });

  test('invalid download keeps previous cache', () async {
    await nucleoCache(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir, '40').refresh();
    final repo = nucleoCache(serve((_) => ok('<html>oops</html>')), dir, '40');
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
    expect((await repo.loadCached())!.trips.length, 3);
  });
}
