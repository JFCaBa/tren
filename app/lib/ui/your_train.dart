import 'package:material_ui/material_ui.dart';

import '../domain/position.dart';
import '../follow/follow_logic.dart';

/// The followed train while another station is on screen, like a ride-hailing app's "your car"
/// strip: countdown, platform and where it is. Tap to open its station.
class YourTrainStrip extends StatelessWidget {
  const YourTrainStrip({super.key, required this.train, this.reading, required this.nowUtc, this.onTap});
  final FollowedTrain train;
  final TrainReading? reading;
  final DateTime nowUtc;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = reading;
    final canceled = r?.canceled == true;
    final headline = canceled ? 'Cancelado' : waitText(expectedDeparture(train, r), nowUtc);
    final status = canceled ? '' : liveStatusText(delaySec: r?.delaySec, canceled: false);
    final where = canceled ? null : whereText(train.route, train.stopId, r?.seen);
    final live = r?.platform;
    final platform = live ?? train.usualPlatform;
    final fg = scheme.onPrimaryContainer;
    final small = theme.textTheme.bodySmall?.copyWith(color: fg);
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Icon(Icons.notifications_active, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Tu tren', style: small?.copyWith(fontWeight: FontWeight.w700)),
                Text(train.title,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (status.isNotEmpty) Text(status, style: small),
                if (where != null) Text(where, style: small, maxLines: 2),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(headline,
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800, color: canceled ? scheme.error : fg,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              if (platform != null)
                Text(live != null ? 'Vía $platform' : 'Vía $platform (habitual)', style: small?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ]),
        ),
      ),
    );
  }
}
