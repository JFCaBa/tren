/// index.json: every Cercanías núcleo and every station, published nightly.
class IndexStop {
  const IndexStop({required this.id, required this.name, required this.lat, required this.lon, required this.nucleos});
  final String id;
  final String name;
  final double lat;
  final double lon;

  /// Núcleos whose trains call here (usually one; a few stations have two).
  final List<String> nucleos;

  factory IndexStop.fromJson(Map<String, dynamic> j) => IndexStop(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        nucleos: (j['nucleos'] as List).cast<String>(),
      );
}

class NucleoInfo {
  const NucleoInfo({required this.id, required this.name, required this.feedPath});
  final String id;
  final String name;
  final String feedPath;
}

class NucleoIndex {
  const NucleoIndex({required this.generatedAt, required this.nucleos, required this.stops});
  final DateTime generatedAt;
  final List<NucleoInfo> nucleos;
  final List<IndexStop> stops;

  NucleoInfo? nucleo(String id) {
    for (final n in nucleos) {
      if (n.id == id) return n;
    }
    return null;
  }

  factory NucleoIndex.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 2) throw FormatException('unsupported index version ${j['version']}');
    return NucleoIndex(
      generatedAt: DateTime.parse(j['generated_at'] as String),
      nucleos: [
        for (final n in j['nucleos'] as List)
          NucleoInfo(id: n['id'] as String, name: n['name'] as String, feedPath: n['feed'] as String),
      ],
      stops: [for (final s in j['stops'] as List) IndexStop.fromJson(s as Map<String, dynamic>)],
    );
  }
}
