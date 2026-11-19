// Drives the real app through the store screens with a fixed clock and chosen realtime data,
// so screenshots and the preview video are the same every time. Not part of `flutter test`.
//
//   flutter test integration_test/store_test.dart -d <simulator> \
//     --dart-define=DEMO_DATA=<dir with index.json and feed_10.json>
//
// It prints "SCENE <name>" and holds each screen for [hold] so a host script can capture it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/positions.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/location.dart';
import 'package:proximotren/main.dart';
import 'package:proximotren/ui/departure_row.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const dataDir = String.fromEnvironment('DEMO_DATA');
const hold = Duration(seconds: 4);

/// Friday morning rush at Madrid-Atocha.
final madrid = tz.getLocation('Europe/Madrid');
var _elapsed = Duration.zero;
tz.TZDateTime clock() => tz.TZDateTime(madrid, 2026, 11, 20, 8, 12, 5).add(_elapsed);

class _Location implements LocationSource {
  @override
  Future<(double, double)?> current({bool requestPermission = false}) async => (40.4067, -3.6893);
}

class _Rt implements RealtimeClient {
  final trips = <String, RtTrip>{};
  @override
  Future<RtSnapshot> fetch() async {
    final now = clock().toUtc();
    return RtSnapshot(fetchedAt: now, feedTimestamp: now, trips: Map.of(trips));
  }
}

class _Positions implements PositionsClient {
  /// tripId -> (stopId, platform)
  final platforms = <String, (String, String)>{};
  @override
  Future<PlatformSnapshot> fetch() async {
    final now = clock().toUtc();
    return PlatformSnapshot(fetchedAt: now, feedTimestamp: now, byTrip: {
      for (final e in platforms.entries) e.key: (stopId: e.value.$1, platform: e.value.$2, at: now),
    });
  }
}

http.Client files() => MockClient((req) async {
      final name = switch (req.url.path.split('/').last) {
        'index.json' => 'index.json',
        '10.json' => 'feed_10.json',
        _ => null,
      };
      if (name == null) return http.Response('not found', 404);
      return http.Response.bytes(await File('$dataDir/$name').readAsBytes(), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screens', (tester) async {
    tzdata.initializeTimeZones();
    SharedPreferences.setMockInitialValues({
      // Shortcuts a commuter would have.
      'recent_stations': '["18000","18101","18002","37002"]',
    });
    final cache = Directory.systemTemp.createTempSync('store');
    final rt = _Rt();
    final positions = _Positions();
    final c = AppController(files(), cache, rt, _Location(), await SharedPreferences.getInstance(),
        clock: clock, positions: positions);

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> scene(String name) async {
      await tester.pump(const Duration(milliseconds: 600));
      // ignore: avoid_print
      print('SCENE $name');
      await tester.runAsync(() => Future<void>.delayed(hold));
      await tester.pump();
    }

    /// Live data for the station on screen: everything on time, one train late, one canceled,
    /// live platforms for the trains arriving now.
    Future<void> liveFor(String stopId, {int late = 5, int canceled = 3}) async {
      _elapsed += const Duration(seconds: 61); // the app asks for positions at most once a minute
      final ds = c.board!.departures;
      for (final d in ds) {
        rt.trips[d.tripId] = const RtTrip(delaySec: 20, canceled: false);
      }
      if (ds.length > late) rt.trips[ds[late].tripId] = const RtTrip(delaySec: 300, canceled: false);
      if (ds.length > canceled) rt.trips[ds[canceled].tripId] = const RtTrip(delaySec: null, canceled: true);
      for (final d in ds.take(3)) {
        final p = d.usualPlatform ?? '${2 + ds.indexOf(d)}';
        positions.platforms[d.tripId] = (stopId, p);
      }
      await tester.runAsync(c.retry);
      await tester.pump();
    }

    await tester.pumpWidget(ProximoTrenApp(controller: c));
    await until(() => c.board?.departures.isNotEmpty == true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await liveFor('18000');
    await scene('board');

    // A train's remaining stops.
    await tester.tap(find.byType(NextTrainCard));
    await tester.pumpAndSettle();
    await scene('stops');
    await tester.tap(find.byType(NextTrainCard));
    await tester.pumpAndSettle();

    // Filter by a destination.
    final chips = find.byType(FilterChip);
    await tester.tap(chips.at(1));
    await tester.pumpAndSettle();
    await liveFor('18000', late: 1, canceled: 3);
    await scene('filter');
    await tester.tap(chips.at(0));
    await tester.pumpAndSettle();

    // Search another station.
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Sol');
    await tester.pumpAndSettle();
    await scene('search');
    await tester.tap(find.text('Sol').last);
    await tester.pumpAndSettle();
    await until(() => c.station?.id == '18101' && c.board?.departures.isNotEmpty == true);
    await liveFor('18101');
    await scene('platform');
  });
}
