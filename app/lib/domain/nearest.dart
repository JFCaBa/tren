import 'dart:math' as math;

import '../data/feed.dart';

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h.clamp(0, 1)));
}

/// Closest stop in a straight line. [stops] must not be empty.
(Stop, double) nearestStop(List<Stop> stops, double lat, double lon) {
  if (stops.isEmpty) throw ArgumentError.value(stops, 'stops', 'must not be empty');
  Stop? best;
  var bestM = double.infinity;
  for (final s in stops) {
    final m = haversineMeters(lat, lon, s.lat, s.lon);
    if (m < bestM) {
      best = s;
      bestM = m;
    }
  }
  return (best!, bestM);
}
