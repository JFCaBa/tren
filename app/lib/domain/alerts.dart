import '../data/alerts.dart';

/// Renfe route ids are `<núcleo:2>T<4 digits><line>`, e.g. `10T0013C4a`.
final _routeId = RegExp(r'^(\d{2})T\d{4}([A-Za-z0-9]+)$');

/// Leading hashtags Renfe puts on line alerts ("#MadC4a ").
final _tags = RegExp(r'^(#\S+\s*)+');

/// A Renfe alert as the station shows it: the line it is about (null for a station alert).
typedef StationAlert = ({String? line, String text});

/// Alerts in effect at [now] about [stopId] or one of [lines] ((núcleo, line) of the trains that
/// call there). Station alerts first, then by line; each alert once.
List<StationAlert> alertsFor(List<RenfeAlert> alerts,
    {required String stopId, required Set<(String, String)> lines, required DateTime now}) {
  final atStation = <StationAlert>[], onLines = <StationAlert>[];
  final seen = <String>{};
  for (final a in alerts) {
    if (a.start != null && a.start!.isAfter(now)) continue;
    if (a.end != null && !a.end!.isAfter(now)) continue;
    final text = a.text.replaceFirst(_tags, '').trim();
    if (text.isEmpty || !seen.add(text)) continue;
    if (a.stopIds.contains(stopId)) {
      atStation.add((line: null, text: text));
      continue;
    }
    String? line;
    for (final r in a.routeIds) {
      final m = _routeId.firstMatch(r);
      if (m != null && lines.contains((m.group(1)!, m.group(2)!))) {
        line = m.group(2);
        break;
      }
    }
    if (line != null) {
      onLines.add((line: line, text: text));
    } else {
      seen.remove(text);
    }
  }
  onLines.sort((a, b) => a.line!.compareTo(b.line!));
  return [...atStation, ...onLines];
}
