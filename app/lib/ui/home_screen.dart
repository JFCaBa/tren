import 'package:material_ui/material_ui.dart';
import 'package:timezone/timezone.dart' as tz;

import '../app_controller.dart';
import '../domain/board.dart';
import 'departure_row.dart';
import 'station_picker.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  Future<void> _pick(BuildContext context) async {
    final feed = controller.feed;
    if (feed == null) return;
    final id = await pickStation(context, feed.stops, controller.coords);
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
    if (c.feed == null) {
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
                    child: Text(c.station!.name,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (c.distanceMeters != null) Text(_distance(c.distanceMeters!), style: theme.textTheme.bodyMedium),
                  const Icon(Icons.expand_more),
                ]),
              ),
            ),
            if (board != null) ..._warnings(context, board),
            if (board?.toValencia != null) _Section(title: '→ València Nord', departures: board!.toValencia!),
            if (board?.fromValencia != null) _Section(title: '→ Gandia / Moixent', departures: board!.fromValencia!),
          ],
          const SizedBox(height: 24),
          Text(_footer(), textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  List<Widget> _warnings(BuildContext context, Board b) => [
        if (!b.feedCoversToday || b.feedStale) const _Banner('El horario puede estar desactualizado'),
        if (b.rtStale) const _Banner('Sin tiempo real: se muestran horas previstas'),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.departures});
  final String title;
  final List<Departure> departures;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const Divider(),
          if (departures.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Sin trenes próximos'))
          else
            for (final d in departures) DepartureRow(d),
        ]),
      );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;

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
      ]),
    );
  }
}
