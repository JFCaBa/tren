import 'package:material_ui/material_ui.dart';

import '../data/nucleo_index.dart';
import '../domain/nearest.dart';
import 'names.dart';

/// Returned by [pickStation] when the user wants the nearest station again.
const useLocationChoice = '__location__';

/// Bottom sheet with every station grouped by núcleo: the current núcleo first, the rest by
/// name; inside each, nearest first when the position is known, else alphabetical.
Future<String?> pickStation(BuildContext context, NucleoIndex index, String? currentNucleo, (double, double)? coords) {
  double? dist(IndexStop s) => coords == null ? null : haversineMeters(coords.$1, coords.$2, s.lat, s.lon);
  final nucleos = [...index.nucleos]..sort((a, b) {
      if (a.id == b.id) return 0;
      if (a.id == currentNucleo) return -1;
      if (b.id == currentNucleo) return 1;
      return a.name.compareTo(b.name);
    });
  final items = <Object>[]; // NucleoInfo header or IndexStop
  for (final n in nucleos) {
    final stops = index.stops.where((s) => s.nucleos.contains(n.id)).toList()
      ..sort((a, b) => coords != null ? dist(a)!.compareTo(dist(b)!) : a.name.compareTo(b.name));
    if (stops.isEmpty) continue;
    items
      ..add(n)
      ..addAll(stops);
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (ctx, scroll) => ListView.builder(
        controller: scroll,
        itemCount: items.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Usar mi ubicación'),
              onTap: () => Navigator.pop(ctx, useLocationChoice),
            );
          }
          final item = items[i - 1];
          if (item is NucleoInfo) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(item.name, style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            );
          }
          final s = item as IndexStop;
          final d = dist(s);
          return ListTile(
            title: Text(shortStopName(s.name)),
            trailing: d == null ? null : Text(d < 1000 ? '${d.round()} m' : '${(d / 1000).toStringAsFixed(0)} km'),
            onTap: () => Navigator.pop(ctx, s.id),
          );
        },
      ),
    ),
  );
}
