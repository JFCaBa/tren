import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../domain/board.dart';
import '../ui/names.dart';

/// App Group shared with the iOS widget extension.
const widgetAppGroup = 'group.com.jfcaba.proximotren';
const widgetDataKey = 'next_trains';
const iosWidgetKind = 'NextTrainsWidget';
const androidWidgetProvider = 'NextTrainsWidgetProvider';

/// Trains handed to the widget, so it keeps going for hours without the app: it drops those that
/// have left and shows up to 4.
const widgetTrains = 60;

/// Even unchanged, the data is written again after this long, with the time of the app's latest
/// real time: the widget trusts the app's delays only while that is recent.
const widgetRewriteEvery = Duration(minutes: 5);

int _epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// What the home screen widget draws, without the time it was written (so equal boards compare
/// equal). Trains that already left are not included.
Map<String, Object?> widgetSnapshot(String station, Board board, DateTime now, {String? via}) => {
      'station': shortStopName(station),
      'via': via == null ? null : shortStopName(via),
      'trains': [
        for (final d in board.departures.where((d) => !d.estimated.isBefore(now)).take(widgetTrains))
          {
            'line': d.line,
            'color': d.color,
            'dest': shortStopName(d.dest),
            // Scheduled times: the widget adds the delay it trusts (its own real time or this one).
            'sched': _epoch(d.scheduled),
            'arrSched': d.arrival == null ? null : _epoch(d.arrival!.time.subtract(Duration(seconds: d.delaySec ?? 0))),
            'delaySec': d.delaySec,
            'canceled': d.canceled,
            'platform': d.livePlatform ?? d.usualPlatform,
            'live': d.livePlatform != null,
            'rt': d.realtimeById ? d.tripId : null,
          },
      ],
    };

/// Writes the widget's data when it changes. Loading, failed or empty boards keep the last one,
/// so the widget does not flash its empty message while the app is busy.
class WidgetPublisher {
  WidgetPublisher({Future<void> Function(String json)? write}) : _write = write ?? _homeWidgetWrite;

  final Future<void> Function(String json) _write;
  String? _last;
  DateTime? _lastAt;

  static Future<void> _homeWidgetWrite(String json) async {
    await HomeWidget.saveWidgetData<String>(widgetDataKey, json);
    await HomeWidget.updateWidget(iOSName: iosWidgetKind, androidName: androidWidgetProvider);
  }

  /// [rtAt]: when the real time the board used was downloaded. The widget weighs the delays it
  /// is handed by this, not by when they were written: a board computed offline carries none
  /// and must not hide the widget's own, newer real time.
  Future<void> publish(String? station, Board? board, DateTime now, {String? via, DateTime? rtAt}) async {
    if (station == null || board == null) return;
    final snap = widgetSnapshot(station, board, now, via: via);
    if ((snap['trains'] as List).isEmpty) return;
    final usedRt = !board.rtStale && rtAt != null;
    // Gaining or losing real time is a change; its exact time is not (it moves every poll).
    final key = jsonEncode({...snap, 'hasRt': usedRt});
    if (key == _last && _lastAt != null && now.difference(_lastAt!) < widgetRewriteEvery) return;
    _last = key;
    _lastAt = now;
    try {
      await _write(jsonEncode({
        ...snap,
        'updatedAt': _epoch(now),
        'rtAt': usedRt ? _epoch(rtAt) : null,
      }));
    } catch (_) {
      _last = null; // try again next time
    }
  }
}
