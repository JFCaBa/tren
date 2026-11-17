import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/data/nucleo_index.dart';
import 'package:proximotren/ui/station_picker.dart';

void main() {
  final index = NucleoIndex.fromJson(
      jsonDecode(File('test/fixtures/index.json').readAsStringSync()) as Map<String, dynamic>);
  List<String> ids(String q) => searchStops(index, q).map((s) => s.id).toList();

  test('search ignores case, accents and punctuation', () {
    expect(ids('chamartin'), ['17000']);
    expect(ids('ATOCHA'), ['18000']);
    expect(ids('valencia nord'), ['65000']);
    expect(ids('estacio del'), ['65000']);
  });

  test('empty or unmatched query finds nothing', () {
    expect(ids(''), isEmpty);
    expect(ids('  '), isEmpty);
    expect(ids('zzz'), isEmpty);
  });

  test('names that start with the query come first, then the rest by name', () {
    // "a": Atocha starts with it (short name), the others only contain it
    final r = ids('a');
    expect(r.first, '18000');
    expect(r.toSet(), {'18000', '17000', '18002', '64200', '65000', '69110', 'X1'});
    expect(ids('pa'), ['18002', 'X1']); // Parla starts with it, comPArtida contains it
  });

  Future<String?> openAndSearch(WidgetTester tester, String query, String tap) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => picked = await pickStation(context, index, '10', null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('typing filters the list and tapping a result picks it', (tester) async {
    expect(await openAndSearch(tester, 'gandia', 'Gandia'), '69110');
  });

  testWidgets('the open keyboard does not cover the last result', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => pickStation(context, index, '10', null), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'a'); // all 7 stations
    await tester.pumpAndSettle();
    // the last result, scrolled as far as it goes, ends above the keyboard
    await tester.scrollUntilVisible(find.text('València Nord'), 100, scrollable: find.byType(Scrollable).last);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(find.text('València Nord')).dy, lessThanOrEqualTo(800 - 350));
  });

  testWidgets('results show their núcleo and the grouped list comes back when cleared', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => pickStation(context, index, '10', null), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Madrid'), findsOneWidget); // group header
    await tester.enterText(find.byType(TextField), 'silla');
    await tester.pumpAndSettle();
    expect(find.text('Silla'), findsOneWidget);
    expect(find.text('Valencia'), findsOneWidget); // subtitle
    expect(find.text('Atocha'), findsNothing);
    expect(find.text('Usar mi ubicación'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'qqq');
    await tester.pumpAndSettle();
    expect(find.text('Ninguna estación coincide'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Atocha'), findsOneWidget);
  });
}
