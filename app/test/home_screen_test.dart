import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/app_controller.dart';
import 'dart:convert';

import 'package:proximotren/data/alerts.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/follow/follow_logic.dart';
import 'package:proximotren/follow/follow_tracker.dart';
import 'package:proximotren/follow/follower.dart';
import 'package:proximotren/ui/departure_row.dart';
import 'package:proximotren/ui/home_screen.dart';
import 'package:proximotren/ui/your_train.dart';
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
        alerts: AlertsClient(server.client),
      );

  Future<AppController> started(WidgetTester tester) async {
    final c = await make();
    await tester.runAsync(c.start);
    return c;
  }

  Future<void> show(WidgetTester tester, AppController c, {Follower? follower, FollowTracker? tracker}) =>
      tester.pumpWidget(MaterialApp(home: HomeScreen(controller: c, follower: follower, tracker: tracker)));

  testWidgets('renders station, filter chips, departures and Datos: Renfe', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.text('Silla'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Todos'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Gandia'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'València Nord'), findsOneWidget);
    expect(find.text('1:04 h'), findsOneWidget); // T1 at Silla 18:55 + 9 min RT delay
    expect(find.text('18:55'), findsOneWidget); // scheduled, struck out
    final late = tester.widget<Text>(find.text('19:04'));
    expect(late.style?.color, lateColor(tester.element(find.text('19:04'))));
    expect(find.textContaining('Datos: Renfe'), findsOneWidget);
    expect(find.textContaining(RegExp(r'En vivo · \d\d:\d\d')), findsOneWidget);
  });

  testWidgets('the first train is shown large, the rest as rows', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    final first = c.board!.departures.firstWhere((d) => !d.canceled);
    expect(find.byType(NextTrainCard), findsOneWidget);
    expect(tester.widget<NextTrainCard>(find.byType(NextTrainCard)).d.id, first.id);
    expect(find.byType(DepartureRow), findsNWidgets(c.board!.departures.length - 1));
  });

  testWidgets('recent stations are shortcuts', (tester) async {
    final c = await started(tester);
    c.selectStation('69110');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await show(tester, c);
    final chip = find.widgetWithText(ActionChip, 'Silla');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();
    expect(c.station!.id, '64200');
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

  testWidgets('Otra parada… picks a stop: chip, only trains that reach it, arrival time', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    await tester.ensureVisible(find.widgetWithText(ActionChip, 'Otra parada…'));
    await tester.tap(find.widgetWithText(ActionChip, 'Otra parada…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'gand');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Gandia'));
    await tester.pumpAndSettle();
    expect(c.via, '69110');
    expect(find.widgetWithText(FilterChip, '→ Gandia'), findsOneWidget);
    expect(find.text('→ València Nord'), findsNothing);
    expect(find.text('llega a Gandia 19:49'), findsOneWidget); // 19:40 scheduled + 9 min RT delay
    await tester.tap(find.widgetWithText(FilterChip, 'Todos'));
    await tester.pumpAndSettle();
    expect(c.via, isNull);
    expect(find.textContaining('llega a'), findsNothing);
  });

  testWidgets('Renfe alerts for the station and its lines: a line that opens them', (tester) async {
    Map<String, dynamic> a(String text, Map<String, String> entity) => {
          'activePeriod': [
            {'start': '1'},
          ],
          'informedEntity': [entity],
          'descriptionText': {
            'translation': [
              {'text': text, 'language': 'es'},
            ],
          },
        };
    server.alertsBody = jsonEncode({
      'entity': [
        {'id': '1', 'alert': a('#ValC1 Obras en la C1.', {'routeId': '40T0001C1'})},
        {'id': '2', 'alert': a('Ascensor de Silla fuera de servicio.', {'stopId': '64200'})},
        {'id': '3', 'alert': a('Otra estación.', {'stopId': '99999'})},
      ],
    });
    final c = await started(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await show(tester, c);
    expect(find.text('2 avisos de Renfe'), findsOneWidget);
    await tester.tap(find.text('2 avisos de Renfe'));
    await tester.pumpAndSettle();
    expect(find.text('Avisos de Renfe'), findsOneWidget);
    expect(find.text('Ascensor de Silla fuera de servicio.'), findsOneWidget);
    expect(find.text('Obras en la C1.'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'C1'), findsOneWidget);
    expect(find.text('Otra estación.'), findsNothing);
  });

  testWidgets('no alerts, or the feed fails: no alerts line', (tester) async {
    final c = await started(tester); // alerts.json answers 404
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await show(tester, c);
    expect(find.textContaining('aviso'), findsNothing);
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

  testWidgets('Ver más adds trains and hides once all are shown', (tester) async {
    server.feed40Override = manyTrainsFeed(12);
    final c = await started(tester);
    await tester.binding.setSurfaceSize(const Size(800, 3000)); // everything fits: no scroll
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester, c);
    expect(c.board!.departures, hasLength(8));
    await tester.tap(find.text('Ver más'));
    await tester.pump();
    expect(c.board!.departures, hasLength(12));
    expect(find.text('Ver más'), findsNothing);
  });

  testWidgets('no Ver más when every train is shown', (tester) async {
    final c = await started(tester);
    await show(tester, c);
    expect(find.text('Ver más'), findsNothing);
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

  group('seguir un tren', () {
    final bell = find.byIcon(Icons.notifications_active);

    testWidgets('long press follows: bell, the card becomes that train, snackbar with undo', (tester) async {
      final c = await started(tester);
      final f = FakeFollower();
      await show(tester, c, follower: f);
      final rows = find.byType(DepartureRow);
      final second = tester.widget<DepartureRow>(rows.first).d;
      await tester.longPress(rows.first);
      await tester.pump();
      expect(f.current!.tripId, second.tripId);
      expect(f.current!.stopId, c.station!.id);
      expect(f.current!.route.last.$1, c.station!.id);
      expect(tester.widget<NextTrainCard>(find.byType(NextTrainCard)).d.id, second.id);
      expect(find.descendant(of: find.byType(NextTrainCard), matching: find.text('Siguiendo')), findsOneWidget);
      expect(find.textContaining('Siguiendo '), findsOneWidget); // snackbar
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Deshacer'));
      await tester.pump();
      expect(f.current, isNull);
    });

    testWidgets('long press on the followed train stops following', (tester) async {
      final c = await started(tester);
      final f = FakeFollower();
      await show(tester, c, follower: f);
      await tester.longPress(find.byType(NextTrainCard));
      await tester.pump();
      expect(f.current, isNotNull);
      await tester.longPress(find.byType(NextTrainCard));
      await tester.pump();
      expect(f.current, isNull);
      expect(find.text('Has dejado de seguirlo'), findsOneWidget);
    });

    testWidgets('notifications denied says so, with Ajustes', (tester) async {
      final c = await started(tester);
      final f = FakeFollower(granted: false);
      await show(tester, c, follower: f);
      await tester.longPress(find.byType(NextTrainCard));
      await tester.pump();
      expect(find.text('Activa las notificaciones de Andén para seguir trenes'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // snackbar slid in
      await tester.tap(find.text('Ajustes'));
      expect(f.settingsOpened, 1);
    });

    testWidgets('the open card offers Seguir este tren', (tester) async {
      final c = await started(tester);
      final f = FakeFollower();
      await show(tester, c, follower: f);
      await tester.tap(find.byType(NextTrainCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seguir este tren'));
      await tester.pump();
      expect(f.current, isNotNull);
      expect(find.text('Dejar de seguir'), findsOneWidget);
    });

    testWidgets('no follower: no bell, no buttons', (tester) async {
      final c = await started(tester);
      await show(tester, c);
      await tester.tap(find.byType(NextTrainCard));
      await tester.pumpAndSettle();
      expect(find.text('Seguir este tren'), findsNothing);
      expect(bell, findsNothing);
    });

    testWidgets('a train at another station: Tu tren strip, live, tap opens its station', (tester) async {
      final c = await started(tester);
      final f = FakeFollower()
        ..current = FollowedTrain(
            tripId: 'X1',
            stopId: '69110',
            scheduled: DateTime.utc(2026, 11, 15, 17, 20),
            title: '18:20 a Gandia',
            usualPlatform: '1',
            route: const [('64200', 'Silla'), ('69110', 'Otra')]);
      final tracker = FollowTracker(
          follower: f,
          periodic: TimerLog().create,
          clock: () => DateTime.utc(2026, 11, 15, 17, 0),
          fetch: (t, s) async => const TrainReading(delaySec: 120, seen: (stopId: '64200', status: 'STOPPED_AT')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await show(tester, c, follower: f, tracker: tracker);
      final strip = find.byType(YourTrainStrip);
      expect(strip, findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('Tu tren')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('18:20 a Gandia')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('22 min')), findsOneWidget); // 18:00 now, 18:20 + 2
      expect(find.descendant(of: strip, matching: find.text('Retraso 2 min')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('En Silla · a 1 parada')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('Vía 1 (habitual)')), findsOneWidget);
      // Opening the station loads its schedule over (fake) HTTP: run it outside the fake clock.
      await tester.runAsync(() async {
        tester.widget<YourTrainStrip>(strip).onTap!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(c.station!.id, '69110');
      tracker.dispose();
    });
  });
}
