import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

import '../data/feed.dart';
import '../data/realtime.dart';

const _rtMaxAge = Duration(minutes: 2);
const _feedMaxAge = Duration(days: 3);
const _graceAfterDeparture = Duration(seconds: 60);

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
}

class Board {
  const Board({
    required this.toValencia,
    required this.fromValencia,
    required this.rtStale,
    required this.feedStale,
    required this.feedCoversToday,
  });

  /// Null when no trip in that direction serves the stop (e.g. towards València Nord at València Nord).
  final List<Departure>? toValencia;
  final List<Departure>? fromValencia;
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
Board computeBoard(Feed feed, String stopId, tz.TZDateTime now, RtSnapshot? rt, {int perDirection = 3}) {
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

  final byDir = <String, List<Departure>>{};
  final servedDirs = <String>{};

  for (final trip in feed.trips) {
    final idx = trip.times.indexWhere((t) => t.$1 == stopId);
    if (idx < 0 || idx == trip.times.length - 1) continue; // not served, or terminates here
    servedDirs.add(trip.dir);
    final secs = trip.times[idx].$2;
    final rtTrip = rtFresh && trip.dates.length == 1 ? rt.trips[trip.id] : null;

    for (final day in days) {
      if (!trip.dates.contains(_iso(day.year, day.month, day.day))) continue;
      final scheduled = serviceTime(loc, day.year, day.month, day.day, secs);
      final delay = rtTrip?.canceled == true ? null : rtTrip?.delaySec;
      final live = delay != null || rtTrip?.canceled == true;
      final estimated = delay != null ? scheduled.add(Duration(seconds: delay)) : scheduled;
      if (estimated.isBefore(now.subtract(_graceAfterDeparture))) continue;
      byDir.putIfAbsent(trip.dir, () => []).add(Departure(
            tripId: trip.id,
            line: trip.line,
            dest: trip.dest,
            scheduled: scheduled,
            estimated: estimated,
            delaySec: delay,
            live: live,
            canceled: rtTrip?.canceled ?? false,
            minutes: math.max(0, estimated.difference(now).inSeconds ~/ 60),
          ));
    }
  }

  List<Departure>? pick(String dir) {
    if (!servedDirs.contains(dir)) return null;
    final list = byDir[dir] ?? [];
    list.sort((a, b) => a.estimated.compareTo(b.estimated));
    return list.take(perDirection).toList();
  }

  return Board(
    toValencia: pick('in'),
    fromValencia: pick('out'),
    rtStale: !rtFresh,
    feedStale: now.difference(feed.generatedAt) > _feedMaxAge,
    feedCoversToday: feed.validFrom.compareTo(today) <= 0 && today.compareTo(feed.validTo) <= 0,
  );
}
