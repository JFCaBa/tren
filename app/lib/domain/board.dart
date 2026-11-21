import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

import '../data/feed.dart';
import '../data/realtime.dart';
import 'train.dart';

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
    this.usualPlatform,
    this.livePlatform,
    this.route = const [],
    this.arrival,
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

  /// Platform this train usually uses at the station (learned), and the one Renfe reports live.
  final String? usualPlatform;
  final String? livePlatform;

  /// (stopId, name) from the train's first stop up to and including this station: where it is
  /// now is told against these (domain/position.dart).
  final List<(String, String)> route;

  /// When it gets to the stop the user is going to (the chosen stop, or the only destination
  /// selected), delay applied; null without one.
  final StopTime? arrival;

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
    this.hasMore = false,
    this.reachable = const [],
    this.lines = const {},
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

  /// More trains than [departures] are left in the feed window (a larger limit would show them).
  final bool hasMore;

  /// (stopId, name) of every stop some train reaches after this station, on any day, by name.
  final List<(String, String)> reachable;

  /// (núcleo, line) of every train that calls here, on any day.
  final Set<(String, String)> lines;
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
  Map<String, String> livePlatforms = const {},
  String? via,
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

  // Light candidates first; the per-stop list is only built for the [limit] shown.
  final candidates = <({Departure d, Feed feed, Trip trip, int idx, int? arr, tz.TZDateTime day, int? delay})>[];
  final destCount = <String, int>{};
  final reachableIds = <Feed, Set<String>>{};
  final lines = <(String, String)>{};

  for (final feed in feeds) {
    for (final trip in feed.trips) {
      final idx = trip.times.indexWhere((t) => t.$1 == stopId);
      if (idx < 0 || idx == trip.times.length - 1) continue; // not served, or terminates here
      destCount[trip.dest] = (destCount[trip.dest] ?? 0) + 1;
      lines.add((feed.nucleo, trip.line));
      final later = reachableIds.putIfAbsent(feed, () => <String>{});
      for (final (id, _) in trip.times.skip(idx + 1)) {
        if (id != stopId) later.add(id);
      }
      int? arr;
      if (via != null) {
        final i = trip.times.indexWhere((t) => t.$1 == via, idx + 1);
        if (i < 0) continue; // does not get there after this station
        arr = i;
      } else {
        if (destinations.isNotEmpty && !destinations.contains(trip.dest)) continue;
        if (destinations.length == 1) arr = trip.times.length - 1;
      }
      final secs = trip.times[idx].$2;
      final rtTrip = rtFresh && trip.dates.length == 1 ? rt.trips[trip.id] : null;

      for (final day in days) {
        if (!trip.dates.contains(_iso(day.year, day.month, day.day))) continue;
        final scheduled = serviceTime(loc, day.year, day.month, day.day, secs);
        final delay = rtTrip?.canceled == true ? null : rtTrip?.delaySec;
        final live = delay != null || rtTrip?.canceled == true;
        final estimated = delay != null ? scheduled.add(Duration(seconds: delay)) : scheduled;
        if (estimated.isBefore(now.subtract(_graceAfterDeparture))) continue;
        candidates.add((
          d: Departure(
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
          ),
          feed: feed,
          trip: trip,
          idx: idx,
          arr: arr,
          day: day,
          delay: delay,
        ));
      }
    }
  }

  candidates.sort((a, b) => a.d.estimated.compareTo(b.d.estimated));
  final shown = candidates.take(limit).toList();
  final names = <Feed, Map<String, String>>{
    for (final f in {for (final c in shown) c.feed, ...reachableIds.keys}) f: {for (final s in f.stops) s.id: s.name},
  };
  StopTime? arrivalOf(({Departure d, Feed feed, Trip trip, int idx, int? arr, tz.TZDateTime day, int? delay}) c) {
    final i = c.arr;
    if (i == null) return null;
    final (id, secs) = c.trip.times[i];
    return StopTime(
      stopId: id,
      name: names[c.feed]![id] ?? id,
      time: serviceTime(loc, c.day.year, c.day.month, c.day.day, secs).add(Duration(seconds: c.delay ?? 0)),
    );
  }

  final departures = [
    for (final c in shown)
      Departure(
        tripId: c.d.tripId,
        line: c.d.line,
        dest: c.d.dest,
        scheduled: c.d.scheduled,
        estimated: c.d.estimated,
        delaySec: c.d.delaySec,
        live: c.d.live,
        canceled: c.d.canceled,
        minutes: c.d.minutes,
        color: c.d.color,
        usualPlatform: _usualPlatform(c.feed, stopId, c.trip.id),
        // Renfe only reports a platform while the train arrives; a trip id that repeats on other
        // days must not lend it to tomorrow's run.
        livePlatform: c.d.minutes <= _livePlatformWithinMinutes ? livePlatforms[c.trip.id] : null,
        route: [
          for (final (id, _) in c.trip.times.take(c.idx + 1)) (id, names[c.feed]![id] ?? id),
        ],
        arrival: arrivalOf(c),
        stops: [
          for (final (id, secs) in c.trip.times.skip(c.idx))
            StopTime(
              stopId: id,
              name: names[c.feed]![id] ?? id,
              time: serviceTime(loc, c.day.year, c.day.month, c.day.day, secs).add(Duration(seconds: c.delay ?? 0)),
            ),
        ],
      ),
  ];
  final dests = destCount.keys.toList()
    ..sort((a, b) {
      final byCount = destCount[b]!.compareTo(destCount[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  final have = {for (final f in feeds) f.nucleo};
  final reachable = <String, String>{
    for (final e in reachableIds.entries)
      for (final id in e.value) id: names[e.key]![id] ?? id,
  }.entries.map((e) => (e.key, e.value)).toList()
    ..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));

  return Board(
    departures: departures,
    destinations: dests,
    missingNucleos: [for (final n in requiredNucleos) if (!have.contains(n)) n],
    rtStale: !rtFresh,
    feedStale: feeds.any((f) => now.difference(f.generatedAt) > _feedMaxAge),
    hasMore: candidates.length > shown.length,
    reachable: reachable,
    lines: lines,
    feedCoversToday: feeds.isNotEmpty && feeds.every((f) => f.validFrom.compareTo(today) <= 0 && today.compareTo(f.validTo) <= 0),
  );
}

const _livePlatformWithinMinutes = 15;

String? _usualPlatform(Feed feed, String stopId, String tripId) {
  final train = trainNumber(tripId);
  return train == null ? null : feed.platforms[stopId]?[train];
}
