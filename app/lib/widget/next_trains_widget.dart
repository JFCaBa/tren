import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../domain/board.dart';
import '../ui/names.dart';

/// App Group shared with the iOS widget extension.
const widgetAppGroup = 'group.com.jfcaba.proximotren';
const widgetDataKey = 'next_trains';
const iosWidgetKind = 'NextTrainsWidget';
const androidWidgetProvider = 'NextTrainsWidgetProvider';

/// Trains handed to the widget: it drops those that have left and shows up to 4.
const widgetTrains = 8;

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
            'dep': _epoch(d.estimated),
            'sched': _epoch(d.scheduled),
            'delayMin': d.delaySec == null ? null : (d.delaySec! / 60).round(),
            'platform': d.livePlatform ?? d.usualPlatform,
            'live': d.livePlatform != null,
            'canceled': d.canceled,
            'arrival': d.arrival == null ? null : _epoch(d.arrival!.time),
          },
      ],
    };

/// Writes the widget's data when it changes. Loading, failed or empty boards keep the last one,
/// so the widget does not flash its empty message while the app is busy.
class WidgetPublisher {
  WidgetPublisher({Future<void> Function(String json)? write}) : _write = write ?? _homeWidgetWrite;

  final Future<void> Function(String json) _write;
  String? _last;

  static Future<void> _homeWidgetWrite(String json) async {
    await HomeWidget.saveWidgetData<String>(widgetDataKey, json);
    await HomeWidget.updateWidget(iOSName: iosWidgetKind, androidName: androidWidgetProvider);
  }

  Future<void> publish(String? station, Board? board, DateTime now, {String? via}) async {
    if (station == null || board == null) return;
    final snap = widgetSnapshot(station, board, now, via: via);
    if ((snap['trains'] as List).isEmpty) return;
    final key = jsonEncode(snap);
    if (key == _last) return;
    _last = key;
    try {
      await _write(jsonEncode({...snap, 'updatedAt': _epoch(now)}));
    } catch (_) {
      _last = null; // try again next time
    }
  }
}
