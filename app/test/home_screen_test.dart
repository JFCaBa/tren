import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/feed_repository.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/ui/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

void main() {
  late Directory dir;
  late FakeServer server;
  late FakeLocation location;

  setUpAll(tzdata.initializeTimeZones);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('home');
    server = FakeServer();
    location = FakeLocation()..immediate = nearSilla;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppController> started(WidgetTester tester) async {
    final c = AppController(
      FeedRepository(server.client, dir),
      RealtimeClient(server.client),
      location,
      await SharedPreferences.getInstance(),
      clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
      periodic: TimerLog().create,
    );
    await tester.runAsync(c.start);
    return c;
  }

  testWidgets('renders both sections and Datos: Renfe', (tester) async {
    final c = await started(tester);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    expect(find.text('Silla'), findsOneWidget);
    expect(find.text('→ València Nord'), findsOneWidget);
    expect(find.text('→ Gandia / Moixent'), findsOneWidget);
    expect(find.text('64 min'), findsOneWidget); // T1 at Silla 18:55 + 9 min RT delay
    expect(find.text('(+9)'), findsOneWidget);
    expect(find.textContaining('Datos: Renfe'), findsOneWidget);
    expect(find.textContaining(RegExp(r'actualizado a las \d\d:\d\d')), findsOneWidget);
    expect(find.text('C1'), findsWidgets);
    expect(find.textContaining('→ Gandia'), findsWidgets);
  });

  testWidgets('shows retry on first-launch offline', (tester) async {
    server.feedFails = true;
    final c = await started(tester);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.textContaining('No se ha podido descargar'), findsOneWidget);
  });

  testWidgets('shows searching while location is pending', (tester) async {
    location.immediate = null; // never answers during the test
    final c = AppController(
      FeedRepository(server.client, dir),
      RealtimeClient(server.client),
      location,
      await SharedPreferences.getInstance(),
      clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
      periodic: TimerLog().create,
    );
    await tester.runAsync(() async {
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    expect(find.text('Buscando tu estación…'), findsOneWidget);
    expect(find.text('Elegir estación'), findsNothing);
  });

  testWidgets('asks to pick a station without location', (tester) async {
    location.immediate = null;
    final c = AppController(
      FeedRepository(server.client, dir),
      RealtimeClient(server.client),
      _NullLocation(),
      await SharedPreferences.getInstance(),
      clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
      periodic: TimerLog().create,
    );
    await tester.runAsync(c.start);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));
    expect(find.text('Elegir estación'), findsOneWidget);
    await tester.tap(find.text('Elegir estación'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gandia').last);
    await tester.pumpAndSettle();
    expect(c.station!.id, '69110');
  });
}

class _NullLocation extends FakeLocation {
  @override
  Future<(double, double)?> current({bool requestPermission = false}) async => null;
}
