/// Schedule data published nightly by the pipeline (feed.json v1).
class Stop {
  const Stop({required this.id, required this.name, required this.lat, required this.lon, required this.lines});

  final String id;
  final String name;
  final double lat;
  final double lon;
  final List<String> lines;

  factory Stop.fromJson(Map<String, dynamic> j) => Stop(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        lines: (j['lines'] as List).cast<String>(),
      );
}

class Trip {
  const Trip({
    required this.id,
    required this.line,
    required this.dir,
    required this.dest,
    required this.dates,
    required this.times,
  });

  final String id;
  final String line;

  /// 'in' (towards València Nord) or 'out'.
  final String dir;
  final String dest;

  /// Service dates, 'YYYY-MM-DD'.
  final Set<String> dates;

  /// (stopId, seconds since service-day midnight), in stop order.
  final List<(String, int)> times;

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: j['id'] as String,
        line: j['line'] as String,
        dir: j['dir'] as String,
        dest: j['dest'] as String,
        dates: (j['dates'] as List).cast<String>().toSet(),
        times: [for (final t in j['times'] as List) ((t as List)[0] as String, (t[1] as num).toInt())],
      );
}

class Feed {
  const Feed({
    required this.generatedAt,
    required this.validFrom,
    required this.validTo,
    required this.stops,
    required this.trips,
  });

  final DateTime generatedAt;
  final String validFrom;
  final String validTo;
  final List<Stop> stops;
  final List<Trip> trips;

  factory Feed.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 1) throw FormatException('unsupported feed version ${j['version']}');
    return Feed(
      generatedAt: DateTime.parse(j['generated_at'] as String),
      validFrom: j['valid_from'] as String,
      validTo: j['valid_to'] as String,
      stops: [for (final s in j['stops'] as List) Stop.fromJson(s as Map<String, dynamic>)],
      trips: [for (final t in j['trips'] as List) Trip.fromJson(t as Map<String, dynamic>)],
    );
  }
}
