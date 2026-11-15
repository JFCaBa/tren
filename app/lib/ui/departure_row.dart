import 'package:material_ui/material_ui.dart';

import '../domain/board.dart';
import 'names.dart';

const lineColors = {'C1': Color(0xFF7AB3DE), 'C2': Color(0xFFF79529)};

String hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class LineBadge extends StatelessWidget {
  const LineBadge(this.line, {super.key});
  final String line;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: lineColors[line] ?? Colors.grey, borderRadius: BorderRadius.circular(6)),
        child: Text(line, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      );
}

class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d, {super.key});
  final Departure d;

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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          LineBadge(d.line),
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
                Text(d.minutes == 0 ? 'ahora' : '${d.minutes} min',
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
  }
}
