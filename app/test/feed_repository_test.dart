import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proximotren/data/feed_repository.dart';

final feedBody = File('test/fixtures/feed.json').readAsStringSync();

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
    final repo = FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir);
    expect(await repo.loadCached(), isNull);
    final feed = await repo.refresh();
    expect(feed.trips.length, 2);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
    expect((await repo.loadCached())!.trips.length, 2);
  });

  test('sends etag and keeps cache on 304', () async {
    await FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = FeedRepository(serve((_) => http.Response('', 304)), dir);
    final cached = await repo.loadCached();
    final feed = await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
    expect(identical(feed, cached), isTrue);
  });

  test('replaces cache on 200 with new etag', () async {
    await FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final newer = feedBody.replaceFirst('2026-11-22', '2026-11-23');
    await FeedRepository(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir).refresh();
    final repo = FeedRepository(serve((_) => http.Response('', 304)), dir);
    expect((await repo.loadCached())!.validTo, '2026-11-23');
    await repo.refresh();
    expect(requests.last.headers['If-None-Match'], '"b"');
  });

  test('falls back to cache on network error', () async {
    await FeedRepository(serve((_) => ok(feedBody)), dir).refresh();
    final repo = FeedRepository(MockClient((_) async => throw const SocketException('offline')), dir);
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
  });

  test('test_first_launch_offline_reports_error', () async {
    final repo = FeedRepository(MockClient((_) async => throw const SocketException('offline')), dir);
    expect(await repo.loadCached(), isNull);
    await expectLater(repo.refresh(), throwsA(isA<FeedUnavailable>()));
  });

  test('timeout without cache throws FeedUnavailable', () async {
    final never = Completer<http.Response>();
    final repo = FeedRepository(MockClient((_) => never.future), dir, timeout: const Duration(milliseconds: 50));
    await expectLater(repo.refresh(), throwsA(isA<FeedUnavailable>()));
  });

  test('default timeout is 15 s', () {
    expect(FeedRepository(MockClient((_) async => http.Response('', 500)), dir).timeout, const Duration(seconds: 15));
  });

  test('corrupt cache treated as missing', () async {
    File('${dir.path}/feed.json').writeAsStringSync('{"version":1,"trips":[');
    final repo = FeedRepository(serve((_) => ok(feedBody)), dir);
    expect(await repo.loadCached(), isNull);
    expect((await repo.refresh()).trips.length, 2);
    expect(requests.single.headers.containsKey('If-None-Match'), isFalse);
  });

  test('etag sent belongs to the feed this repository holds', () async {
    await FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final stale = FeedRepository(serve((_) => http.Response('', 304)), dir);
    await stale.loadCached(); // holds feed "a"
    final newer = feedBody.replaceFirst('2026-11-22', '2026-11-23');
    await FeedRepository(serve((_) => ok(newer, headers: {'etag': '"b"'})), dir).refresh();
    await stale.refresh();
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('refresh without loadCached still uses disk cache', () async {
    await FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = FeedRepository(serve((_) => http.Response('', 304)), dir);
    expect((await repo.refresh()).trips.length, 2);
    expect(requests.last.headers['If-None-Match'], '"a"');
  });

  test('concurrent refresh shares one request', () async {
    final gate = Completer<void>();
    final repo = FeedRepository(MockClient((req) async {
      requests.add(req);
      await gate.future;
      return ok(feedBody);
    }), dir);
    final a = repo.refresh(), b = repo.refresh();
    gate.complete();
    expect(identical(await a, await b), isTrue);
    expect(requests.length, 1);
  });

  test('write failure still returns downloaded feed', () async {
    final notADir = File('${dir.path}/file')..writeAsStringSync('x');
    final repo = FeedRepository(serve((_) => ok(feedBody)), Directory(notADir.path));
    expect((await repo.refresh()).trips.length, 2);
  });

  test('invalid download keeps previous cache', () async {
    await FeedRepository(serve((_) => ok(feedBody, headers: {'etag': '"a"'})), dir).refresh();
    final repo = FeedRepository(serve((_) => ok('<html>oops</html>')), dir);
    final cached = await repo.loadCached();
    expect(await repo.refresh(), same(cached));
    expect((await repo.loadCached())!.trips.length, 2);
  });
}
