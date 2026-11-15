import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

import '../data/feed.dart';
import '../data/realtime.dart';

const _rtMaxAge = Duration(minutes: 2);
const _feedMaxAge = Duration(days: 3);
const _graceAfterDeparture = Duration(seconds: 60);

/// A stop this train still makes, from the user's station to the end of the trip.
class StopTime {
  const StopTime({required this.stopId, required this.name, required this.time});
  final String stopId;
  final String name;

  /// Estimated when the train is live (delay applied), scheduled otherwise.
  final tz.TZDateTime time;
}

class Departure {
  const Departure({
    required this.tripId,
    required this.line,
    required this.dest,
    required this.scheduled,
    required this.estimated,
    required this.delaySec,
    required this.live,
    required this.canceled,
    required this.minutes,
    this.color = greyLine,
    this.stops = const [],
  });

  final String tripId;
  final String line;
  final String dest;
  final tz.TZDateTime scheduled;
  final tz.TZDateTime estimated;

  /// Null when the time is only the scheduled one.
  final int? delaySec;
  final bool live;
  final bool canceled;
  final int minutes;

  /// ARGB line color from the núcleo feed.
  final int color;
  final List<StopTime> stops;

  /// One train on one service day (a trip id alone could repeat across days).
  String get id => '$tripId@${scheduled.toIso8601String()}';
}

class Board {
  const Board({
    required this.departures,
    required this.destinations,
    required this.missingNucleos,
    required this.rtStale,
    required this.feedStale,
    required this.feedCoversToday,
  });

  /// Next trains from the station, by estimated time, after applying the destination filter.
  final List<Departure> departures;

  /// Every destination reachable from the station in the feed window, most frequent first.
  final List<String> destinations;

  /// Núcleos the station needs whose schedule is not available.
  final List<String> missingNucleos;
  final bool rtStale;
  final bool feedStale;
  final bool feedCoversToday;
}

String _iso(int y, int m, int d) =>
    '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

/// GTFS times count from "noon minus 12h" of the service day, which keeps
/// civil times right on daylight-saving change days.
tz.TZDateTime serviceTime(tz.Location loc, int y, int m, int d, int secs) =>
    tz.TZDateTime(loc, y, m, d, 12).subtract(const Duration(hours: 12)).add(Duration(seconds: secs));

/// Service days and civil times are always Renfe's (Europe/Madrid), whatever zone [now] is in.
Board computeBoard(
  List<Feed> feeds,
  String stopId,
  tz.TZDateTime now,
  RtSnapshot? rt, {
  Set<String> destinations = const {},
  int limit = 8,
  List<String> requiredNucleos = const [],
}) {
  final loc = tz.getLocation('Europe/Madrid');
  now = tz.TZDateTime.from(now, loc);
  final rtFresh = rt != null &&
      now.difference(rt.fetchedAt) < _rtMaxAge &&
      now.difference(rt.feedTimestamp) < _rtMaxAge;

  final days = [
    for (final offset in const [-1, 0, 1])
      tz.TZDateTime(loc, now.year, now.month, now.day + offset), // Dart normalises day overflow
  ];
  final today = _iso(now.year, now.month, now.day);

  final departures = <Departure>[];
  final destCount = <String, int>{};

  for (final feed in feeds) {
    final names = {for (final s in feed.stops) s.id: s.name};
    for (final trip in feed.trips) {
      final idx = trip.times.indexWhere((t) => t.$1 == stopId);
      if (idx < 0 || idx == trip.times.length - 1) continue; // not served, or terminates here
      destCount[trip.dest] = (destCount[trip.dest] ?? 0) + 1;
      if (destinations.isNotEmpty && !destinations.contains(trip.dest)) continue;
      final secs = trip.times[idx].$2;
      final rtTrip = rtFresh && trip.dates.length == 1 ? rt.trips[trip.id] : null;

      for (final day in days) {
        if (!trip.dates.contains(_iso(day.year, day.month, day.day))) continue;
        final scheduled = serviceTime(loc, day.year, day.month, day.day, secs);
        final delay = rtTrip?.canceled == true ? null : rtTrip?.delaySec;
        final live = delay != null || rtTrip?.canceled == true;
        final estimated = delay != null ? scheduled.add(Duration(seconds: delay)) : scheduled;
        if (estimated.isBefore(now.subtract(_graceAfterDeparture))) continue;
        departures.add(Departure(
          tripId: trip.id,
          line: trip.line,
          dest: trip.dest,
          scheduled: scheduled,
          estimated: estimated,
          delaySec: delay,
          live: live,
          canceled: rtTrip?.canceled ?? false,
          minutes: math.max(0, estimated.difference(now).inSeconds ~/ 60),
          color: feed.lineColors[trip.line] ?? greyLine,
          stops: [
            for (final (id, s) in trip.times.skip(idx))
              StopTime(
                stopId: id,
                name: names[id] ?? id,
                time: serviceTime(loc, day.year, day.month, day.day, s).add(Duration(seconds: delay ?? 0)),
              ),
          ],
        ));
      }
    }
  }

  departures.sort((a, b) => a.estimated.compareTo(b.estimated));
  final dests = destCount.keys.toList()
    ..sort((a, b) {
      final byCount = destCount[b]!.compareTo(destCount[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  final have = {for (final f in feeds) f.nucleo};

  return Board(
    departures: departures.take(limit).toList(),
    destinations: dests,
    missingNucleos: [for (final n in requiredNucleos) if (!have.contains(n)) n],
    rtStale: !rtFresh,
    feedStale: feeds.any((f) => now.difference(f.generatedAt) > _feedMaxAge),
    feedCoversToday: feeds.isNotEmpty && feeds.every((f) => f.validFrom.compareTo(today) <= 0 && today.compareTo(f.validTo) <= 0),
  );
}
