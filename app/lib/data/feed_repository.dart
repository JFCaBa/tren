import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'feed.dart';

/// No schedule available: no usable cache and the download failed.
class FeedUnavailable implements Exception {
  const FeedUnavailable(this.cause);
  final Object cause;
  @override
  String toString() => 'FeedUnavailable($cause)';
}

/// Downloads feed.json with a conditional GET and keeps the last good copy on disk.
/// The repository owns its cache: the ETag it sends always belongs to the feed it holds.
class FeedRepository {
  FeedRepository(this._client, this._dir, {this.timeout = const Duration(seconds: 15)});

  final http.Client _client;
  final Directory _dir;
  final Duration timeout;

  bool _loaded = false;
  Feed? _feed;
  String? _feedEtag;
  Future<Feed>? _inFlight;

  File get _feedFile => File('${_dir.path}/feed.json');
  File get _metaFile => File('${_dir.path}/feed_meta.json');

  /// The feed on disk (or the one already held), null if missing or corrupt.
  Future<Feed?> loadCached() async {
    if (_loaded) return _feed;
    _loaded = true;
    try {
      _feed = Feed.fromJson(jsonDecode(await _feedFile.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return _feed = null;
    }
    try {
      _feedEtag = (jsonDecode(await _metaFile.readAsString()) as Map<String, dynamic>)['etag'] as String?;
    } catch (_) {
      _feedEtag = null;
    }
    return _feed;
  }

  /// Returns the newest feed: the downloaded one, or the held one when unchanged (304) or offline.
  /// Concurrent calls share one request. Throws [FeedUnavailable] when there is no feed at all.
  Future<Feed> refresh() => _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<Feed> _refresh() async {
    final cached = await loadCached();
    final http.Response resp;
    final Feed feed;
    final String body;
    try {
      final etag = cached != null ? _feedEtag : null;
      resp = await _client.get(Uri.parse(feedUrl), headers: {'If-None-Match': ?etag}).timeout(timeout);
      if (resp.statusCode == 304 && cached != null) return cached;
      if (resp.statusCode != 200) throw http.ClientException('feed HTTP ${resp.statusCode}');
      body = utf8.decode(resp.bodyBytes);
      feed = Feed.fromJson(jsonDecode(body) as Map<String, dynamic>); // validate before saving
    } catch (e) {
      if (cached != null) return cached;
      throw FeedUnavailable(e);
    }
    _feed = feed;
    _feedEtag = resp.headers['etag'];
    try {
      await _write(_feedFile, body);
      await _write(_metaFile, jsonEncode({
        'etag': _feedEtag,
        'downloaded_at': DateTime.now().toUtc().toIso8601String(),
      }));
    } catch (_) {
      // Disk full or unwritable: still show the fresh feed; next launch downloads again.
    }
    return feed;
  }

  Future<void> _write(File f, String content) async {
    await _dir.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }
}
