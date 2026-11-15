import 'dart:math' as math;

import '../data/feed.dart';

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h.clamp(0, 1)));
}

/// Closest item in a straight line. [items] must not be empty.
(T, double) nearest<T>(List<T> items, double lat, double lon,
    {required double Function(T) latOf, required double Function(T) lonOf}) {
  if (items.isEmpty) throw ArgumentError.value(items, 'items', 'must not be empty');
  T? best;
  var bestM = double.infinity;
  for (final s in items) {
    final m = haversineMeters(lat, lon, latOf(s), lonOf(s));
    if (m < bestM) {
      best = s;
      bestM = m;
    }
  }
  return (best as T, bestM);
}

(Stop, double) nearestStop(List<Stop> stops, double lat, double lon) =>
    nearest(stops, lat, lon, latOf: (s) => s.lat, lonOf: (s) => s.lon);
