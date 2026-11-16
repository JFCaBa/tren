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

  testWidgets('live platform is bold', (tester) async {
    await pump(tester, dep(live: '3', usual: '2'));
    final t = tester.widget<Text>(find.text('Vía 3'));
    expect(t.style?.fontWeight, FontWeight.w700);
    expect(find.textContaining('habitual'), findsNothing);
  });

  testWidgets('usual platform uses the muted color', (tester) async {
    await pump(tester, dep(usual: '2'));
    final t = tester.widget<Text>(find.text('vía 2 · habitual'));
    final ctx = tester.element(find.text('vía 2 · habitual'));
    expect(t.style?.color, Theme.of(ctx).colorScheme.onSurfaceVariant);
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
