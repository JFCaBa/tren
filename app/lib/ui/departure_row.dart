import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../domain/board.dart';
import 'names.dart';

/// "ahora", "N min" under an hour, "h:mm h" from an hour on.
String formatWait(int minutes) {
  if (minutes <= 0) return 'ahora';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')} h';
}

/// Black or white, whichever reads better on [argb] (WCAG relative luminance).
int lineTextColor(int argb) {
  double ch(int shift) {
    final c = ((argb >> shift) & 0xFF) / 255;
    return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  final l = 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0);
  return l > 0.179 ? 0xFF000000 : 0xFFFFFFFF; // crossover where black beats white on WCAG contrast
}

/// "Vía 3" when Renfe reports it live, "vía 2 · habitual" when only learned, else null.
String? platformText(Departure d) {
  if (d.livePlatform != null) return 'Vía ${d.livePlatform}';
  if (d.usualPlatform != null) return 'vía ${d.usualPlatform} · habitual';
  return null;
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
        child: Text(line, style: TextStyle(color: Color(lineTextColor(color)), fontWeight: FontWeight.w700)),
      );
}

/// A gap with no trains this long (minutes, from now for the first train) is called out.
const gapMinutes = 90;

/// The train at [i] comes after [gapMinutes] or more without trains.
bool startsAfterGap(List<Departure> ds, int i) => ds[i].minutes - (i == 0 ? 0 : ds[i - 1].minutes) >= gapMinutes;

/// The train for the large card: the first one that runs (a canceled one stays a row).
int? nextTrainIndex(List<Departure> ds) {
  final i = ds.indexWhere((d) => !d.canceled);
  return i < 0 ? null : i;
}

/// Whole minutes of delay (rounded), or null when not live or the clock time does not change.
int? delayMinutes(Departure d) {
  final s = d.delaySec;
  if (s == null || d.canceled || hhmm(d.scheduled) == hhmm(d.estimated)) return null;
  final m = (s / 60).round();
  return m == 0 ? null : m;
}

/// From this many minutes late a train is marked in amber (1–2 min are routine on Cercanías).
const lateMinutes = 3;

/// The train is late enough to mark.
bool isLate(Departure d) => (delayMinutes(d) ?? 0) >= lateMinutes;

/// Amber for late trains, readable on both themes.
Color lateColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFF0A63A) : const Color(0xFFB86E00);

/// Green for early trains and for "en vivo".
Color goodColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF4FC27F) : const Color(0xFF1F8A4C);

/// The platform as a pill: filled when Renfe reports it live, outlined when only usual.
class PlatformPill extends StatelessWidget {
  const PlatformPill(this.d, {super.key, this.large = false});
  final Departure d;

  /// "Vía 2" instead of just "2".
  final bool large;

  @override
  Widget build(BuildContext context) {
    final p = d.livePlatform ?? d.usualPlatform;
    if (p == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final live = d.livePlatform != null;
    return Semantics(
      label: platformText(d),
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 3 : 1),
        decoration: BoxDecoration(
          color: live ? scheme.onSurface : null,
          border: live ? null : Border.all(color: scheme.outline, width: 1.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          large ? 'Vía $p' : p,
          style: TextStyle(
            color: live ? scheme.surface : scheme.onSurfaceVariant,
            fontWeight: live ? FontWeight.w700 : FontWeight.w600,
            fontSize: large ? 15 : 12,
          ),
        ),
      ),
    );
  }
}

/// "ahora" / "N min" in bold (amber when late), or "Cancelado" in red.
class _Wait extends StatelessWidget {
  const _Wait(this.d, {this.style});
  final Departure d;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (d.canceled) {
      return Text('Cancelado', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error));
    }
    return Text(
      formatWait(d.minutes),
      style: (style ?? theme.textTheme.titleLarge)?.copyWith(
        fontWeight: FontWeight.w700,
        color: isLate(d) ? lateColor(context) : null,
      ),
    );
  }
}

/// Clock time: the scheduled one struck out beside the new one when it moved; a hollow
/// circle when there is no real time for this train ("previsto").
class _Time extends StatelessWidget {
  const _Time(this.d);
  final Departure d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final delay = delayMinutes(d);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!d.live) ...[
          Semantics(
            label: 'previsto',
            child: Icon(Icons.circle_outlined, size: 9, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 4),
        ],
        if (delay != null) ...[
          Text(hhmm(d.scheduled), style: muted?.copyWith(decoration: TextDecoration.lineThrough)),
          const SizedBox(width: 4),
          Text(
            hhmm(d.estimated),
            style: muted?.copyWith(
              color: delay < 0 ? goodColor(context) : (isLate(d) ? lateColor(context) : null),
              fontWeight: FontWeight.w600,
            ),
          ),
        ] else
          Text(hhmm(d.estimated), style: muted?.copyWith(decoration: d.canceled ? TextDecoration.lineThrough : null)),
      ],
    );
  }
}

/// "Seguir este tren" / "Dejar de seguir" under the stops of an open train.
class FollowButton extends StatelessWidget {
  const FollowButton({super.key, required this.followed, required this.onPressed});
  final bool followed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: followed
              ? OutlinedButton.icon(
                  onPressed: onPressed, icon: const Icon(Icons.notifications_off), label: const Text('Dejar de seguir'))
              : FilledButton.tonalIcon(
                  onPressed: onPressed, icon: const Icon(Icons.notifications_active), label: const Text('Seguir este tren')),
        ),
      );
}

class DepartureRow extends StatelessWidget {
  const DepartureRow(this.d,
      {super.key, this.expanded = false, this.onTap, this.followed = false, this.onLongPress, this.onFollow});
  final Departure d;
  final bool expanded;
  final VoidCallback? onTap;

  /// This is the train being followed: shows a bell.
  final bool followed;
  final VoidCallback? onLongPress;

  /// Follow / stop following, offered under the stops; null where following is not available.
  final VoidCallback? onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          LineBadge(d.line, d.color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '→ ${shortStopName(d.dest)}',
              style: theme.textTheme.bodyLarge?.copyWith(decoration: d.canceled ? TextDecoration.lineThrough : null),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (followed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.notifications_active, size: 20, color: theme.colorScheme.primary, semanticLabel: 'Siguiendo'),
            ),
          PlatformPill(d),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [_Wait(d), _Time(d)]),
        ],
      ),
    );
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            // A canceled train stays listed but steps back from the ones that run.
            Opacity(opacity: d.canceled ? 0.55 : 1, child: row),
            if (expanded) _StopList(key: ValueKey('stops-${d.tripId}'), d: d),
            if (expanded && onFollow != null) FollowButton(followed: followed, onPressed: onFollow!),
          ],
        ),
      ),
    );
  }
}

/// The next train, large: what the user looks for while walking to the platform.
class NextTrainCard extends StatelessWidget {
  const NextTrainCard(this.d,
      {super.key, this.expanded = false, this.onTap, this.followed = false, this.where, this.onLongPress, this.onFollow});
  final Departure d;
  final bool expanded;
  final VoidCallback? onTap;
  final bool followed;

  /// Where the followed train is now ("En Atocha · a 2 paradas").
  final String? where;
  final VoidCallback? onLongPress;
  final VoidCallback? onFollow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    LineBadge(d.line, d.color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '→ ${shortStopName(d.dest)}',
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (followed) ...[
                      Icon(Icons.notifications_active, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('Siguiendo',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: _Wait(d, style: theme.textTheme.displaySmall)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [PlatformPill(d, large: true), const SizedBox(height: 4), _Time(d)],
                    ),
                  ],
                ),
                if (where != null && !d.canceled)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Icon(Icons.train, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(where!,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
                if (expanded) ...[const SizedBox(height: 8), _StopList(key: ValueKey('stops-${d.tripId}'), d: d)],
                if (expanded && onFollow != null) FollowButton(followed: followed, onPressed: onFollow!),
              ],
            ),
          ),
        ),
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
