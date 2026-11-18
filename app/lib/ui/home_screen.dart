import 'package:material_ui/material_ui.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../config.dart';
import '../domain/board.dart';
import 'departure_row.dart';
import 'names.dart';
import 'station_picker.dart';

/// Beyond this, the nearest station is probably not useful; say so.
const farFromCercaniasMeters = 25000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.openUrl = _launchExternal});
  final AppController controller;

  /// Opens a web page; injectable for tests.
  final Future<void> Function(Uri) openUrl;

  static Future<void> _launchExternal(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open $url');
    }
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get controller => widget.controller;

  /// [Departure.id] whose stops are shown; only one at a time.
  String? _expanded;

  void _toggle(String key) => setState(() => _expanded = _expanded == key ? null : key);

  /// Pixels from the end of the list at which more trains are added.
  static const _loadMoreWithin = 300.0;

  /// A page was added and the list has not been laid out with it yet.
  bool _loadPending = false;

  late final ScrollController _scroll = ScrollController()..addListener(_onScroll);

  /// Near the end of the list: add more trains (cheap, computed from the loaded schedule).
  /// One page per frame: the scroll extents only grow once the new rows are laid out.
  void _onScroll() {
    final p = _scroll.position;
    if (_loadPending || !p.hasContentDimensions || p.extentAfter >= _loadMoreWithin) return;
    _loadPending = true;
    controller.loadMore();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPending = false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _openPrivacy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.openUrl(Uri.parse(privacyUrl));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('No se pudo abrir la política de privacidad')));
    }
  }

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
            if (c.retrying)
              const CircularProgressIndicator()
            else
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
        controller: _scroll,
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
              // Scrolling near the end also loads more; the button covers lists that fit without scrolling.
              if (board.hasMore) Center(child: TextButton(onPressed: c.loadMore, child: const Text('Ver más'))),
            ],
          ],
          const SizedBox(height: 24),
          Text(_footer(), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
          Center(
            child: TextButton(
              onPressed: () => _openPrivacy(context),
              child: Text('Privacidad', style: theme.textTheme.bodySmall?.copyWith(decoration: TextDecoration.underline)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _warnings(BuildContext context, Board b) => [
        if (!controller.manualStation && (controller.distanceMeters ?? 0) > farFromCercaniasMeters)
          _Banner('Estás a ${(controller.distanceMeters! / 1000).round()} km de la estación de Cercanías más cercana'),
        if (b.missingNucleos.isNotEmpty)
          _Banner('Horario incompleto: falta ${b.missingNucleos.map((n) => controller.nucleoName(n) ?? n).join(', ')}',
              onRetry: controller.retrying ? null : controller.retry),
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
