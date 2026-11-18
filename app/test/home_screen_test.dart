import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/app_controller.dart';
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

  Future<AppController> make() async => AppController(
        server.client,
        dir,
        RealtimeClient(server.client),
        location,
        await SharedPreferences.getInstance(),
        clock: () => tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 0),
        periodic: TimerLog().create,
      );

  Future<AppController> started(WidgetTester tester) async {
    final c = await make();
    await tester.runAsync(c.start);
    return c;
  }

  Future<void> show(WidgetTester tester, AppController c) =>
      tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c)));

  testWidgets('renders station, filter chips, departures and Datos: Renfe', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.text('Silla'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Todos'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Gandia'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'València Nord'), findsOneWidget);
    expect(find.text('1:04 h'), findsOneWidget); // T1 at Silla 18:55 + 9 min RT delay
    expect(find.text('(+9)'), findsOneWidget);
    expect(find.textContaining('Datos: Renfe'), findsOneWidget);
    expect(find.textContaining(RegExp(r'actualizado a las \d\d:\d\d')), findsOneWidget);
  });

  testWidgets('Privacidad link opens the privacy policy page', (tester) async {
    final c = await started(tester);
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(controller: c, openUrl: (u) async => opened.add(u))));
    await tester.scrollUntilVisible(find.text('Privacidad'), 200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first);
    await tester.tap(find.text('Privacidad'));
    await tester.pump();
    expect(opened, [Uri.parse('https://jfcaba.github.io/tren/privacidad.html')]);
  });

  testWidgets('Privacidad link shows a message when the page cannot be opened', (tester) async {
    final c = await started(tester);
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(controller: c, openUrl: (u) async => throw Exception('no browser'))));
    await tester.scrollUntilVisible(find.text('Privacidad'), 200,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first);
    await tester.tap(find.text('Privacidad'));
    await tester.pump();
    expect(find.text('No se pudo abrir la política de privacidad'), findsOneWidget);
  });

  testWidgets('tapping a chip filters the list', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.text('→ València Nord'), findsWidgets);
    await tester.tap(find.widgetWithText(FilterChip, 'Gandia'));
    await tester.pumpAndSettle();
    expect(c.filters, {'Gandia'});
    expect(find.text('→ València Nord'), findsNothing);
    expect(find.text('→ Gandia'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Todos'));
    await tester.pumpAndSettle();
    expect(c.filters, isEmpty);
    expect(find.text('→ València Nord'), findsWidgets);
  });

  testWidgets('scrolling to the end shows more trains', (tester) async {
    server.feed40Override = manyTrainsFeed(30);
    final c = await started(tester);
    await show(tester, c);
    expect(c.board!.departures, hasLength(8));
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(c.board!.departures.length, greaterThan(8));
  });

  testWidgets('line badge uses the feed color', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    final badge = tester.widget<Container>(
        find.ancestor(of: find.text('C2').first, matching: find.byType(Container)).first);
    expect((badge.decoration! as BoxDecoration).color, const Color(0xFFF79529));
  });

  testWidgets('tapping a train expands its stops, one at a time', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.byKey(const ValueKey('stops-T1')), findsNothing);
    await tester.tap(find.text('→ Gandia'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stops-T1')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('stops-T1')), matching: find.text('Gandia')), findsOneWidget);

    await tester.tap(find.text('→ València Nord').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stops-T1')), findsNothing);
    expect(find.byKey(const ValueKey('stops-T2')), findsOneWidget);

    await tester.tap(find.text('→ València Nord').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stops-T2')), findsNothing);
  });

  testWidgets('long destinations are shortened and wrap to two lines', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.textContaining('Estació del Nord'), findsNothing);
    final rows = tester.widgetList<Text>(find.textContaining('→ ')).where((t) => t.maxLines != null);
    expect(rows, isNotEmpty);
    for (final t in rows) {
      expect(t.maxLines, 2, reason: t.data);
    }
  });

  testWidgets('shows searching while location is pending', (tester) async {
    location.immediate = null; // never answers during the test
    final c = await make();
    await tester.runAsync(() async {
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await show(tester, c);
    expect(find.text('Buscando tu estación…'), findsOneWidget);
    expect(find.text('Elegir estación'), findsNothing);
  });

  testWidgets('no realtime banner before the first poll answers', (tester) async {
    server.rtHangs = true;
    final c = await make();
    await tester.runAsync(() async {
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await show(tester, c);
    expect(find.text('Silla'), findsOneWidget);
    expect(find.textContaining('Sin tiempo real'), findsNothing);
  });

  testWidgets('realtime banner after a failed poll', (tester) async {
    server.rtFails = true;
    final c = await started(tester);
    await show(tester, c);
    expect(find.textContaining('Sin tiempo real'), findsOneWidget);
  });

  testWidgets('incomplete banner when a nucleo of the station is missing', (tester) async {
    server.failing.add('feeds/10.json');
    location.immediate = nearShared;
    final c = await started(tester);
    await show(tester, c);
    expect(find.textContaining('Horario incompleto: falta Madrid'), findsOneWidget);
  });

  testWidgets('warns when far from any Cercanías station', (tester) async {
    location.immediate = (37.1773, -3.5986); // Granada
    final c = await started(tester);
    await show(tester, c);
    expect(find.textContaining('km de la estación de Cercanías más cercana'), findsOneWidget);
  });

  testWidgets('no far warning near a station', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.textContaining('km de la estación de Cercanías más cercana'), findsNothing);
  });

  testWidgets('retry shows progress instead of the button', (tester) async {
    server.feedFails = true;
    final c = await started(tester);
    server.feedFails = false;
    server.hold('index.json');
    await tester.runAsync(() async {
      c.retry();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await show(tester, c);
    expect(find.text('Reintentar'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    server.release('index.json');
  });

  testWidgets('shows retry on first-launch offline', (tester) async {
    server.feedFails = true;
    final c = await started(tester);
    await show(tester, c);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.textContaining('No se ha podido descargar'), findsOneWidget);
  });

  testWidgets('station picker groups by nucleo and changes station', (tester) async {
    tester.view.physicalSize = const Size(800, 1400); // both groups on screen below the search field
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    location.immediate = null;
    final c = await make();
    await tester.runAsync(() async {
      final s = c.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      location.answer(null);
      await s;
    });
    await show(tester, c);
    expect(find.text('Elegir estación'), findsOneWidget);
    await tester.tap(find.text('Elegir estación'));
    await tester.pumpAndSettle();
    expect(find.text('Madrid'), findsWidgets);
    expect(find.text('Valencia'), findsWidgets);
    await tester.tap(find.text('Parla')); // Madrid group comes first (alphabetical, no current)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    expect(c.station!.id, '18002');
  });
}
