import 'package:material_ui/material_ui.dart';

import '../domain/board.dart';
import 'names.dart';

/// "ahora", "N min" under an hour, "h:mm h" from an hour on.
String formatWait(int minutes) {
  if (minutes <= 0) return 'ahora';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')} h';
}

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class LineBadge extends StatelessWidget {
  const LineBadge(this.line, this.color, {super.key});
  final String line;

  /// ARGB from the núcleo feed.
  final int color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Color(color), borderRadius: BorderRadius.circular(6)),
        child: Text(line, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      );
}

class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d, {super.key, this.expanded = false, this.onTap});
  final Departure d;
  final bool expanded;
  final VoidCallback? onTap;

  String? get _delayText {
    final s = d.delaySec;
    if (s == null) return null;
    final m = (s / 60).round();
    if (m == 0) return null;
    return m > 0 ? '(+$m)' : '(−${-m})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final delay = _delayText;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          LineBadge(d.line, d.color),
          const SizedBox(width: 12),
          Expanded(
            child: Text('→ ${shortStopName(d.dest)}', style: theme.textTheme.bodyLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (d.canceled)
                Text('✕ Cancelado', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error))
              else
                Text(formatWait(d.minutes),
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(hhmm(d.estimated),
                    style: muted?.copyWith(decoration: d.canceled ? TextDecoration.lineThrough : null)),
                if (delay != null && !d.canceled) ...[
                  const SizedBox(width: 4),
                  Text(delay,
                      style: muted?.copyWith(
                          color: d.delaySec! > 0 ? theme.colorScheme.error : Colors.green.shade700,
                          fontWeight: FontWeight.w600)),
                ],
                if (!d.live) ...[const SizedBox(width: 6), Text('previsto', style: muted)],
              ]),
            ],
          ),
        ],
      ),
    );
    return InkWell(
      onTap: onTap,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: Column(children: [
          row,
          if (expanded) _StopList(key: ValueKey('stops-${d.tripId}'), d: d),
        ]),
      ),
    );
  }
}

/// Metro-map style list of the stops still ahead, from the user's station to the end.
class _StopList extends StatelessWidget {
  const _StopList({super.key, required this.d});
  final Departure d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(d.color);
    final stops = d.stops;
    return Padding(
      padding: const EdgeInsets.only(left: 14, bottom: 8),
      child: Column(children: [
        for (var i = 0; i < stops.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 24,
                child: Stack(alignment: Alignment.center, children: [
                  Column(children: [
                    Expanded(child: Container(width: 3, color: i == 0 ? Colors.transparent : color)),
                    Expanded(child: Container(width: 3, color: i == stops.length - 1 ? Colors.transparent : color)),
                  ]),
                  Container(
                    width: i == 0 || i == stops.length - 1 ? 12 : 8,
                    height: i == 0 || i == stops.length - 1 ? 12 : 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(shortStopName(stops[i].name),
                      style: i == 0 ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700) : theme.textTheme.bodyMedium),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(hhmm(stops[i].time), style: theme.textTheme.bodyMedium),
              ),
            ]),
          ),
      ]),
    );
  }
}
