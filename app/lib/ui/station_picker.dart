import 'package:material_ui/material_ui.dart';

import '../data/feed.dart';
import '../domain/nearest.dart';
import 'departure_row.dart';
import 'names.dart';

/// Returned by [pickStation] when the user wants the nearest station again.
const useLocationChoice = '__location__';

/// Bottom sheet listing stations, nearest first when the position is known.
Future<String?> pickStation(BuildContext context, List<Stop> stops, (double, double)? coords) {
  final sorted = [...stops];
  if (coords != null) {
    double d(Stop s) => haversineMeters(coords.$1, coords.$2, s.lat, s.lon);
    sorted.sort((a, b) => d(a).compareTo(d(b)));
  } else {
    sorted.sort((a, b) => a.name.compareTo(b.name));
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        children: [
          ListTile(
            leading: const Icon(Icons.my_location),
            title: const Text('Usar mi ubicación'),
            onTap: () => Navigator.pop(ctx, useLocationChoice),
          ),
          const Divider(),
          for (final s in sorted)
            ListTile(
              title: Text(shortStopName(s.name)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final l in s.lines) Padding(padding: const EdgeInsets.only(left: 4), child: LineBadge(l)),
              ]),
              onTap: () => Navigator.pop(ctx, s.id),
            ),
        ],
      ),
    ),
  );
}
