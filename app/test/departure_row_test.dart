import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/domain/board.dart';
import 'package:proximotren/ui/departure_row.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Departure dep({String? live, String? usual}) {
  final t = tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 10);
  return Departure(
    tripId: 'T',
    line: 'C2',
    dest: 'València Nord',
    scheduled: t,
    estimated: t,
    delaySec: null,
    live: false,
    canceled: false,
    minutes: 10,
    livePlatform: live,
    usualPlatform: usual,
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('platformText: live beats usual, usual is marked, none is null', () {
    expect(platformText(dep(live: '3', usual: '2')), 'Vía 3');
    expect(platformText(dep(usual: '2')), 'vía 2 · habitual');
    expect(platformText(dep()), isNull);
  });

  Future<void> pump(WidgetTester tester, Departure d) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: DepartureRow(d))));

  Departure withTimes({int? delaySec, bool live = true, bool canceled = false, int minutes = 10}) {
    final t = tz.TZDateTime(tz.getLocation('Europe/Madrid'), 2026, 11, 15, 18, 10);
    return Departure(
      tripId: 'T',
      line: 'C2',
      dest: 'València Nord',
      scheduled: t,
      estimated: t.add(Duration(seconds: delaySec ?? 0)),
      delaySec: delaySec,
      live: live,
      canceled: canceled,
      minutes: minutes,
    );
  }

  testWidgets('live platform is a filled pill', (tester) async {
    await pump(tester, dep(live: '3', usual: '2'));
    final box = tester.widget<Container>(find.ancestor(of: find.text('3'), matching: find.byType(Container)).first);
    final ctx = tester.element(find.text('3'));
    expect((box.decoration! as BoxDecoration).color, Theme.of(ctx).colorScheme.onSurface);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('usual platform is an outlined pill', (tester) async {
    await pump(tester, dep(usual: '2'));
    final box = tester.widget<Container>(find.ancestor(of: find.text('2'), matching: find.byType(Container)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.color, isNull);
    expect(d.border, isNotNull);
  });

  testWidgets('a late train: minutes in amber, scheduled time struck out', (tester) async {
    await pump(tester, withTimes(delaySec: 240));
    final ctx = tester.element(find.text('10 min'));
    expect(tester.widget<Text>(find.text('10 min')).style?.color, lateColor(ctx));
    expect(tester.widget<Text>(find.text('18:10')).style?.decoration, TextDecoration.lineThrough);
    expect(tester.widget<Text>(find.text('18:14')).style?.color, lateColor(ctx));
  });

  testWidgets('a routine 1–2 min delay is struck out but not amber', (tester) async {
    await pump(tester, withTimes(delaySec: 120));
    final ctx = tester.element(find.text('10 min'));
    expect(tester.widget<Text>(find.text('10 min')).style?.color, isNot(lateColor(ctx)));
    expect(tester.widget<Text>(find.text('18:10')).style?.decoration, TextDecoration.lineThrough);
    expect(tester.widget<Text>(find.text('18:12')).style?.color, isNot(lateColor(ctx)));
  });

  testWidgets('a canceled train steps back', (tester) async {
    await pump(tester, withTimes(canceled: true));
    expect(find.text('Cancelado'), findsOneWidget);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1));
  });

  testWidgets('no real time: hollow circle labelled previsto', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, withTimes(live: false));
    expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('previsto')), findsWidgets);
    handle.dispose();
  });

  testWidgets('a delay inside the same clock minute is not shown', (tester) async {
    await pump(tester, withTimes(delaySec: 40)); // 18:10:00 → 18:10:40
    expect(find.text('18:10'), findsOneWidget);
    expect(delayMinutes(withTimes(delaySec: 40)), isNull);
  });

  test('nextTrainIndex: first train that runs, null when all are canceled', () {
    expect(nextTrainIndex([withTimes(canceled: true), withTimes()]), 1);
    expect(nextTrainIndex([withTimes(), withTimes(canceled: true)]), 0);
    expect(nextTrainIndex([withTimes(canceled: true)]), isNull);
    expect(nextTrainIndex(const []), isNull);
  });

  test('startsAfterGap: from now for the first train, then from the previous one', () {
    final ds = [withTimes(minutes: 5), withTimes(minutes: 100), withTimes(minutes: 110)];
    expect(startsAfterGap(ds, 0), isFalse);
    expect(startsAfterGap(ds, 1), isTrue);
    expect(startsAfterGap(ds, 2), isFalse);
    expect(startsAfterGap([withTimes(minutes: 330)], 0), isTrue);
  });

  testWidgets('no platform, no extra line', (tester) async {
    await pump(tester, dep());
    expect(find.textContaining('ía '), findsNothing);
  });

  testWidgets('platform is part of the row semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, dep(live: '3'));
    expect(find.bySemanticsLabel(RegExp('Vía 3')), findsWidgets);
    handle.dispose();
  });
}
