import 'package:material_ui/material_ui.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../app_controller.dart';
import '../config.dart';
import '../domain/alerts.dart';
import '../domain/board.dart';
import '../domain/position.dart';
import '../follow/follow_logic.dart';
import '../follow/follow_tracker.dart';
import '../follow/follower.dart';
import 'about_sheet.dart';
import 'departure_row.dart';
import 'names.dart';
import 'station_picker.dart';
import 'your_train.dart';

/// Beyond this, the nearest station is probably not useful; say so.
const farFromCercaniasMeters = 25000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.openUrl = _launchExternal, this.follower, this.tracker});
  final AppController controller;

  /// Follows one train (null where following is not available).
  final Follower? follower;

  /// The followed train, live, for the home screen.
  final FollowTracker? tracker;

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

  Future<void> _pickVia(BuildContext context, List<(String, String)> reachable) async {
    final id = await pickReachableStop(context, reachable);
    if (id != null) controller.setVia(id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([controller, ?widget.follower, ?widget.tracker]),
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
    final alerts = c.stationAlerts;
    // The large card: the followed train when this board lists it, else the first train that runs
    // (canceled ones stay rows).
    final current = widget.follower?.current;
    final followedAt = board == null || current == null ? -1 : board.departures.indexWhere(current.matches);
    final next = board == null ? null : (followedAt >= 0 ? followedAt : nextTrainIndex(board.departures));
    // With a destination filter a long gap is only that destination's: not worth calling out.
    bool gapAt(int i) => c.filters.isEmpty && c.via == null && startsAfterGap(board!.departures, i);
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
            Row(children: [
              Expanded(
                child: InkWell(
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
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          Text(c.station!.nucleos.map((n) => c.nucleoName(n) ?? n).join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                          if (board != null) ?_liveStatus(context, board),
                        ]),
                      ),
                      if (c.distanceMeters != null) Text(_distance(c.distanceMeters!), style: theme.textTheme.bodyMedium),
                      const Icon(Icons.expand_more),
                    ]),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'Información',
                onPressed: () => showAboutSheet(context, onPrivacy: () => _openPrivacy(context)),
              ),
            ]),
            if (alerts.isNotEmpty) _AlertsLine(alerts),
            if (c.recentStations.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final r in c.recentStations)
                    ActionChip(
                      label: Text(shortStopName(r.name)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => c.selectStation(r.id),
                    ),
                ]),
              ),
            ?_yourTrain(context, followedAt),
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
                via: c.via == null ? null : (c.viaName ?? c.via),
                onToggle: c.toggleFilter,
                onClear: c.clearFilters,
                onPickVia: board.reachable.isEmpty ? null : () => _pickVia(context, board.reachable),
              ),
              if (next != null) ...[
                const SizedBox(height: 12),
                if (gapAt(next)) _gapNote(context, board.departures[next]),
                NextTrainCard(board.departures[next],
                    expanded: board.departures[next].id == _expanded,
                    onTap: () => _toggle(board.departures[next].id),
                    followed: next == followedAt,
                    where: next == followedAt
                        ? whereText(current!.route, current.stopId, widget.tracker?.reading?.seen)
                        : null,
                    onLongPress: _followAction(context, board.departures[next], next == followedAt),
                    onFollow: _followAction(context, board.departures[next], next == followedAt)),
                const SizedBox(height: 4),
              ] else
                const Divider(),
              if (board.departures.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Sin trenes próximos'))
              else
                for (var i = 0; i < board.departures.length; i++)
                  if (i != next) ...[
                    if (gapAt(i)) _gapNote(context, board.departures[i]),
                    DepartureRow(board.departures[i],
                        expanded: board.departures[i].id == _expanded,
                        onTap: () => _toggle(board.departures[i].id),
                        followed: i == followedAt,
                        onLongPress: _followAction(context, board.departures[i], i == followedAt),
                        onFollow: _followAction(context, board.departures[i], i == followedAt)),
                  ],
              // Scrolling near the end also loads more; the button covers lists that fit without scrolling.
              if (board.hasMore) Center(child: TextButton(onPressed: c.loadMore, child: const Text('Ver más'))),
            ],
          ],
          const SizedBox(height: 24),
          Text('Datos: Renfe', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
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

  /// The followed train at another station (or no longer on this board): a strip on top.
  Widget? _yourTrain(BuildContext context, int followedAt) {
    final t = widget.tracker?.train ?? widget.follower?.current;
    if (t == null || followedAt >= 0) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: YourTrainStrip(
        train: t,
        reading: widget.tracker?.reading,
        nowUtc: controller.now().toUtc(),
        onTap: controller.station?.id == t.stopId ? null : () => controller.selectStation(t.stopId),
      ),
    );
  }

  /// Long press / panel button: follow [d], or stop following it. Null when following is not
  /// available, or for a canceled train.
  VoidCallback? _followAction(BuildContext context, Departure d, bool followed) {
    final f = widget.follower, station = controller.station;
    if (f == null || station == null || (d.canceled && !followed)) return null;
    return () => _toggleFollow(context, f, FollowedTrain.of(d, station.id), followed);
  }

  List<Widget> _warnings(BuildContext context, Board b) => [
        if (!controller.manualStation && (controller.distanceMeters ?? 0) > farFromCercaniasMeters)
          _Banner('Estás a ${(controller.distanceMeters! / 1000).round()} km de la estación de Cercanías más cercana'),
        if (b.missingNucleos.isNotEmpty)
          _Banner('Horario incompleto: falta ${b.missingNucleos.map((n) => controller.nucleoName(n) ?? n).join(', ')}',
              onRetry: controller.retrying ? null : controller.retry),
        if (!b.feedCoversToday || b.feedStale) const _Banner('El horario puede estar desactualizado'),
      ];

  /// "En vivo · 10:39:12" (green dot) or "Sin tiempo real" (hollow); nothing before the first poll answers.
  Widget? _liveStatus(BuildContext context, Board b) {
    final theme = Theme.of(context);
    final rt = controller.rt;
    final live = !b.rtStale && rt != null;
    if (!live && !controller.rtAttempted) return null;
    final String text;
    if (live) {
      final t = tz.TZDateTime.from(rt.fetchedAt, controller.now().location);
      text = 'En vivo · ${hhmm(t)}:${t.second.toString().padLeft(2, '0')}';
    } else {
      text = 'Sin tiempo real · horas previstas';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Icon(live ? Icons.circle : Icons.circle_outlined,
            size: 8, color: live ? goodColor(context) : theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  /// Called out before a train that comes after a long stretch without any (nights, small stations).
  Widget _gapNote(BuildContext context, Departure d) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text('Sin trenes hasta las ${hhmm(d.estimated)}',
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  static String _distance(double m) =>
      m < 1000 ? '${(m / 10).round() * 10} m' : '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

class _FilterChips extends StatelessWidget {
  const _FilterChips(
      {required this.destinations,
      required this.selected,
      required this.via,
      required this.onToggle,
      required this.onClear,
      required this.onPickVia});
  final List<String> destinations;
  final Set<String> selected;

  /// Name of the chosen stop, if any.
  final String? via;
  final void Function(String) onToggle;
  final VoidCallback onClear;

  /// Opens the «Otra parada…» picker; null when the station reaches nowhere.
  final VoidCallback? onPickVia;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          FilterChip(label: const Text('Todos'), selected: selected.isEmpty && via == null, onSelected: (_) => onClear()),
          if (via != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilterChip(label: Text('→ ${shortStopName(via!)}'), selected: true, onSelected: (_) => onClear()),
            ),
          for (final d in destinations)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilterChip(
                label: Text(shortStopName(d)),
                selected: selected.contains(d),
                onSelected: (_) => onToggle(d),
              ),
            ),
          if (onPickVia != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ActionChip(label: const Text('Otra parada…'), onPressed: onPickVia),
            ),
        ]),
      );
}

/// «⚠ 2 avisos de Renfe» under the station; opens them all.
class _AlertsLine extends StatelessWidget {
  const _AlertsLine(this.alerts);
  final List<StationAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final color = lateColor(context);
    final n = alerts.length;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: TextButton.styleFrom(
            foregroundColor: color, padding: const EdgeInsets.symmetric(horizontal: 4), visualDensity: VisualDensity.compact),
        onPressed: () => _showAlerts(context, alerts),
        icon: const Icon(Icons.warning_amber_rounded, size: 18),
        label: Text(n == 1 ? '1 aviso de Renfe' : '$n avisos de Renfe'),
      ),
    );
  }
}

Future<void> _showAlerts(BuildContext context, List<StationAlert> alerts) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('Avisos de Renfe', style: Theme.of(ctx).textTheme.titleLarge),
            for (final a in alerts)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (a.line != null) ...[
                    Chip(label: Text(a.line!), visualDensity: VisualDensity.compact),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: Text(a.text)),
                ]),
              ),
          ],
        ),
      ),
    );

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

Future<void> _toggleFollow(BuildContext context, Follower follower, FollowedTrain t, bool followed) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  if (followed) {
    await follower.stop();
    messenger.showSnackBar(const SnackBar(content: Text('Has dejado de seguirlo')));
    return;
  }
  final previous = follower.current;
  if (!await _follow(messenger, follower, t)) return;
  if (follower.current != t) return; // a later follow or stop replaced this one meanwhile
  messenger.showSnackBar(SnackBar(
    content: Text('Siguiendo ${t.title}'),
    action: SnackBarAction(
      label: 'Deshacer',
      onPressed: () => previous == null ? follower.stop() : _follow(messenger, follower, previous),
    ),
  ));
}

const _deniedText = 'Activa las notificaciones de Andén para seguir trenes';

/// Follows [t]; on failure says why and returns false.
Future<bool> _follow(ScaffoldMessengerState messenger, Follower follower, FollowedTrain t) async {
  String? problem;
  try {
    if (!await follower.follow(t)) problem = _deniedText;
  } on FollowFailed catch (e) {
    problem = switch (e.reason) {
      FollowFailure.gone => 'Ese tren ya ha salido',
      FollowFailure.network => 'No se pudo seguir: revisa la conexión',
      FollowFailure.notifications => _deniedText,
    };
  } catch (_) {
    problem = 'No se pudo seguir: revisa la conexión';
  }
  if (problem == null) return true;
  messenger.showSnackBar(SnackBar(
    content: Text(problem),
    action: problem == _deniedText ? SnackBarAction(label: 'Ajustes', onPressed: follower.openSettings) : null,
  ));
  return false;
}
