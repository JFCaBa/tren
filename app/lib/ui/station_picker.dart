import 'package:material_ui/material_ui.dart';

import '../data/nucleo_index.dart';
import '../domain/nearest.dart';
import 'names.dart';

/// Returned by [pickStation] when the user wants the nearest station again.
const useLocationChoice = '__location__';

const _accents = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', //
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c',
};
final _alnum = RegExp(r'[a-z0-9]');

/// Lower case, no accents, letters and digits only: "València-Estació" → "valenciaestacio".
String _fold(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final c = _accents[ch] ?? ch;
    if (_alnum.hasMatch(c)) b.write(c);
  }
  return b.toString();
}

/// Stations whose name contains [query], ignoring case, accents and punctuation. Those whose
/// displayed name starts with it come first; each group by displayed name.
List<IndexStop> searchStops(NucleoIndex index, String query) {
  final q = _fold(query);
  if (q.isEmpty) return const [];
  final starts = <IndexStop>[], contains = <IndexStop>[];
  for (final s in index.stops) {
    if (_fold(shortStopName(s.name)).startsWith(q)) {
      starts.add(s);
    } else if (_fold(s.name).contains(q)) {
      contains.add(s);
    }
  }
  int byName(IndexStop a, IndexStop b) => _fold(shortStopName(a.name)).compareTo(_fold(shortStopName(b.name)));
  return [...starts..sort(byName), ...contains..sort(byName)];
}

/// Bottom sheet with a search field above every station grouped by núcleo: the current núcleo
/// first, the rest by name; inside each, nearest first when the position is known, else
/// alphabetical. Typing filters by name across all núcleos.
Future<String?> pickStation(BuildContext context, NucleoIndex index, String? currentNucleo, (double, double)? coords) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // keep the results above the keyboard
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: _Picker(index: index, currentNucleo: currentNucleo, coords: coords),
      ),
    );

class _Picker extends StatefulWidget {
  const _Picker({required this.index, required this.currentNucleo, required this.coords});
  final NucleoIndex index;
  final String? currentNucleo;
  final (double, double)? coords;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _query = '';
  List<IndexStop> _results = const [];
  late final List<Object> _grouped = _group(); // NucleoInfo header or IndexStop

  double? _dist(IndexStop s) {
    final c = widget.coords;
    return c == null ? null : haversineMeters(c.$1, c.$2, s.lat, s.lon);
  }

  List<Object> _group() {
    final current = widget.currentNucleo;
    final nucleos = [...widget.index.nucleos]..sort((a, b) {
        if (a.id == b.id) return 0;
        if (a.id == current) return -1;
        if (b.id == current) return 1;
        return a.name.compareTo(b.name);
      });
    final items = <Object>[];
    for (final n in nucleos) {
      final stops = widget.index.stops.where((s) => s.nucleos.contains(n.id)).toList()
        ..sort((a, b) => widget.coords != null ? _dist(a)!.compareTo(_dist(b)!) : a.name.compareTo(b.name));
      if (stops.isEmpty) continue;
      items
        ..add(n)
        ..addAll(stops);
    }
    return items;
  }

  Widget _stop(BuildContext ctx, IndexStop s, {bool withNucleo = false}) {
    final d = _dist(s);
    return ListTile(
      title: Text(shortStopName(s.name)),
      subtitle: withNucleo ? Text(s.nucleos.map((n) => widget.index.nucleo(n)?.name ?? n).join(' · ')) : null,
      trailing: d == null ? null : Text(d < 1000 ? '${d.round()} m' : '${(d / 1000).toStringAsFixed(0)} km'),
      onTap: () => Navigator.pop(ctx, s.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.trim().isNotEmpty;
    final List<Object> items = searching ? _results : _grouped;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (ctx, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar estación',
              border: OutlineInputBorder(),
            ),
            onChanged: (q) => setState(() {
              _query = q;
              _results = searchStops(widget.index, q);
            }),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemCount: items.length + (searching && items.isEmpty ? 2 : 1),
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return ListTile(
                  leading: const Icon(Icons.my_location),
                  title: const Text('Usar mi ubicación'),
                  onTap: () => Navigator.pop(ctx, useLocationChoice),
                );
              }
              if (items.isEmpty) {
                return const Padding(padding: EdgeInsets.all(16), child: Text('Ninguna estación coincide'));
              }
              final item = items[i - 1];
              if (item is NucleoInfo) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(item.name,
                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                );
              }
              return _stop(ctx, item as IndexStop, withNucleo: searching);
            },
          ),
        ),
      ]),
    );
  }
}
