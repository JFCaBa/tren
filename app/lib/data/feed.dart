/// Schedule data published nightly by the pipeline (feed.json v1).
class Stop {
  const Stop({required this.id, required this.name, required this.lat, required this.lon});

  final String id;
  final String name;
  final double lat;
  final double lon;

  factory Stop.fromJson(Map<String, dynamic> j) => Stop(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
      );
}

class Trip {
  const Trip({
    required this.id,
    required this.line,
    required this.dest,
    required this.dates,
    required this.times,
  });

  final String id;
  final String line;
  final String dest;

  /// Service dates, 'YYYY-MM-DD'.
  final Set<String> dates;

  /// (stopId, seconds since service-day midnight), in stop order.
  final List<(String, int)> times;

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: j['id'] as String,
        line: j['line'] as String,
        dest: j['dest'] as String,
        dates: (j['dates'] as List).cast<String>().toSet(),
        times: [for (final t in j['times'] as List) ((t as List)[0] as String, (t[1] as num).toInt())],
      );
}

const greyLine = 0xFF9E9E9E;

int _argb(Object? hex) {
  final v = hex is String && hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
  return v == null ? greyLine : 0xFF000000 | v;
}

/// Schedule of one Cercanías núcleo (`feeds/<id>.json`, version 2).
class Feed {
  const Feed({
    required this.nucleo,
    required this.name,
    required this.generatedAt,
    required this.validFrom,
    required this.validTo,
    required this.lineColors,
    required this.stops,
    required this.trips,
    this.platforms = const {},
  });

  final String nucleo;
  final String name;
  final DateTime generatedAt;
  final String validFrom;
  final String validTo;

  /// Line -> ARGB color.
  final Map<String, int> lineColors;
  final List<Stop> stops;
  final List<Trip> trips;

  /// Usual platform per stop and train number (`platforms` in the feed; optional).
  final Map<String, Map<String, String>> platforms;

  factory Feed.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 2) throw FormatException('unsupported feed version ${j['version']}');
    return Feed(
      nucleo: j['nucleo'] as String,
      name: j['name'] as String,
      generatedAt: DateTime.parse(j['generated_at'] as String),
      validFrom: j['valid_from'] as String,
      validTo: j['valid_to'] as String,
      lineColors: {for (final e in (j['lines'] as Map? ?? const {}).entries) e.key as String: _argb(e.value)},
      stops: [for (final s in j['stops'] as List) Stop.fromJson(s as Map<String, dynamic>)],
      trips: [for (final t in j['trips'] as List) Trip.fromJson(t as Map<String, dynamic>)],
      platforms: _platforms(j['platforms']),
    );
  }
}

/// Tolerant: anything that is not a map of maps of strings is dropped, never thrown.
Map<String, Map<String, String>> _platforms(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, Map<String, String>>{};
  for (final e in raw.entries) {
    if (e.key is! String || e.value is! Map) continue;
    final byTrain = <String, String>{
      for (final t in (e.value as Map).entries)
        if (t.key is String && t.value is String) t.key as String: t.value as String,
    };
    if (byTrain.isNotEmpty) out[e.key as String] = byTrain;
  }
  return out;
}
