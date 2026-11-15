import 'package:material_ui/material_ui.dart';
import 'package:timezone/timezone.dart' as tz;

import '../app_controller.dart';
import '../domain/board.dart';
import 'departure_row.dart';
import 'names.dart';
import 'station_picker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get controller => widget.controller;

  /// [Departure.id] whose stops are shown; only one at a time.
  String? _expanded;

  void _toggle(String key) => setState(() => _expanded = _expanded == key ? null : key);

  Future<void> _pick(BuildContext context) async {
    final index = controller.index;
    if (index == null) return;
    final current = controller.station?.nucleos.firstOrNull;
    final id = await pickStation(context, index, current, controller.coords);
    if (id == useLocationChoice) {
      controller.useLocation();
    } else if (id != null) {
      controller.selectStation(id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Scaffold(body: SafeArea(child: _body(context))),
      );

  Widget _body(BuildContext context) {
    final c = controller;
    if (c.index == null) {
      if (c.error == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(c.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: c.retry, child: const Text('Reintentar')),
          ]),
        ),
      );
    }
    final theme = Theme.of(context);
    final board = c.board;
    return RefreshIndicator(
      onRefresh: c.retry,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (c.station == null && !c.needsStationPick)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Buscando tu estación…'),
              ]),
            )
          else if (c.station == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(children: [
                const Text('No sabemos dónde estás.'),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => _pick(context), child: const Text('Elegir estación')),
              ]),
            )
          else ...[
            InkWell(
              onTap: () => _pick(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Icon(c.manualStation ? Icons.place_outlined : Icons.my_location, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(shortStopName(c.station!.name),
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis),
                      Text(c.station!.nucleos.map((n) => c.nucleoName(n) ?? n).join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                  if (c.distanceMeters != null) Text(_distance(c.distanceMeters!), style: theme.textTheme.bodyMedium),
                  const Icon(Icons.expand_more),
                ]),
              ),
            ),
            if (board == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              ..._warnings(context, board),
              _FilterChips(
                destinations: board.destinations,
                selected: c.filters,
                onToggle: c.toggleFilter,
                onClear: c.clearFilters,
              ),
              const Divider(),
              if (board.departures.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Sin trenes próximos'))
              else
                for (final d in board.departures)
                  DepartureRow(d, expanded: d.id == _expanded, onTap: () => _toggle(d.id)),
            ],
          ],
          const SizedBox(height: 24),
          Text(_footer(), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  List<Widget> _warnings(BuildContext context, Board b) => [
        if (b.missingNucleos.isNotEmpty)
          _Banner('Horario incompleto: falta ${b.missingNucleos.map((n) => controller.nucleoName(n) ?? n).join(', ')}',
              onRetry: controller.retry),
        if (!b.feedCoversToday || b.feedStale) const _Banner('El horario puede estar desactualizado'),
        if (b.rtStale && controller.rtAttempted) const _Banner('Sin tiempo real: se muestran horas previstas'),
      ];

  String _footer() {
    final rt = controller.rt;
    if (rt == null || controller.board?.rtStale != false) return 'Datos: Renfe';
    final t = tz.TZDateTime.from(rt.fetchedAt, controller.now().location);
    return 'actualizado a las ${hhmm(t)}:${t.second.toString().padLeft(2, '0')} · Datos: Renfe';
  }

  static String _distance(double m) =>
      m < 1000 ? '${(m / 10).round() * 10} m' : '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.destinations, required this.selected, required this.onToggle, required this.onClear});
  final List<String> destinations;
  final Set<String> selected;
  final void Function(String) onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          FilterChip(label: const Text('Todos'), selected: selected.isEmpty, onSelected: (_) => onClear()),
          for (final d in destinations)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilterChip(
                label: Text(shortStopName(d)),
                selected: selected.contains(d),
                onSelected: (_) => onToggle(d),
              ),
            ),
        ]),
      );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.onRetry});
  final String text;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.info_outline, size: 18, color: scheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
        if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Reintentar')),
      ]),
    );
  }
}
