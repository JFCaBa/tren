import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'feed.dart';
import 'nucleo_index.dart';

/// No data available: no usable cache and the download failed.
class DataUnavailable implements Exception {
  const DataUnavailable(this.cause);
  final Object cause;
  @override
  String toString() => 'DataUnavailable($cause)';
}

String _resolve(String base, String path) => Uri.parse('$base/').resolve(path).toString();

JsonCache<NucleoIndex> indexCache(http.Client client, Directory dir) =>
    JsonCache(client, dir,
        url: _resolve(dataUrl, 'index.json'),
        fallbackUrl: _resolve(pagesUrl, 'index.json'),
        name: 'index',
        parse: NucleoIndex.fromJson);

/// [path] is the núcleo's `feed` entry in index.json (defaults to the published layout).
JsonCache<Feed> nucleoCache(http.Client client, Directory dir, String id,
        {String? path, Duration? timeout, Duration? firstTimeout}) =>
    JsonCache(
      client,
      dir,
      url: _resolve(dataUrl, path ?? 'feeds/$id.json'),
      fallbackUrl: _resolve(pagesUrl, path ?? 'feeds/$id.json'),
      name: 'feed_$id',
      parse: Feed.fromJson,
      timeout: timeout ?? const Duration(seconds: 15),
      firstTimeout: firstTimeout ?? const Duration(seconds: 45),
    );

/// Downloads a JSON document with a conditional GET and keeps the last good copy on disk.
/// The cache owns its copy: the ETag it sends always belongs to the value it holds.
class JsonCache<T> {
  JsonCache(
    this._client,
    this._dir, {
    required this.url,
    this.fallbackUrl,
    required this.name,
    required T Function(Map<String, dynamic>) parse,
    this.timeout = const Duration(seconds: 15),
    Duration? firstTimeout,
  })  : _parse = parse, // ignore: prefer_initializing_formals (private field, public param name)
        firstTimeout = firstTimeout ?? timeout; // ignore: prefer_initializing_formals (private field, public param name)

  final http.Client _client;
  final Directory _dir;
  final String url;

  /// Tried when [url] fails (network, non-200/304, unparsable body), before the cached copy.
  final String? fallbackUrl;
  final String name;
  final T Function(Map<String, dynamic>) _parse;
  /// Limit for a refresh when a cached copy exists (falls back to it).
  final Duration timeout;

  /// Limit for the first download, with nothing to fall back to (e.g. Madrid on slow 3G).
  final Duration firstTimeout;

  T? _feed;
  String? _feedEtag;
  Future<T>? _inFlight;

  File get _feedFile => File('${_dir.path}/$name.json');
  File get _metaFile => File('${_dir.path}/${name}_meta.json');

  Future<T?>? _cachedLoad;

  /// The copy on disk (or the one already held), null if missing or corrupt.
  /// Concurrent callers share one read.
  Future<T?> loadCached() async {
    final fromDisk = await (_cachedLoad ??= _loadCached());
    return _feed ?? fromDisk; // a later download wins over the first disk read
  }

  Future<T?> _loadCached() async {
    try {
      _feed = _parse(jsonDecode(await _feedFile.readAsString()) as Map<String, dynamic>);
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
  /// Concurrent calls share one request. Throws [DataUnavailable] when there is no feed at all.
  Future<T> refresh() => _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<T> _refresh() async {
    final cached = await loadCached();
    final etag = cached != null ? _feedEtag : null;
    Object? error;
    for (final u in [url, ?fallbackUrl]) {
      try {
        final resp = await _client
            .get(Uri.parse(u), headers: {'If-None-Match': ?etag})
            .timeout(cached == null ? firstTimeout : timeout);
        if (resp.statusCode == 304 && cached != null) return cached;
        if (resp.statusCode != 200) throw http.ClientException('$name HTTP ${resp.statusCode}');
        final body = utf8.decode(resp.bodyBytes);
        final feed = _parse(jsonDecode(body) as Map<String, dynamic>); // validate before saving
        return await _keep(feed, body, resp.headers['etag']);
      } catch (e) {
        error = e;
      }
    }
    if (cached != null) return cached;
    throw DataUnavailable(error!);
  }

  Future<T> _keep(T feed, String body, String? etag) async {
    _feed = feed;
    _feedEtag = etag;
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
