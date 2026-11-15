import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:proximotren/app_controller.dart';
import 'package:proximotren/data/realtime.dart';
import 'package:proximotren/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('app title is Andén', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('title');
    addTearDown(() => dir.deleteSync(recursive: true));
    final server = FakeServer();
    final location = FakeLocation(); // never answers: start() stays pending, fine for this test
    final c = AppController(server.client, dir, RealtimeClient(server.client), location,
        await SharedPreferences.getInstance(), periodic: TimerLog().create);
    await tester.pumpWidget(ProximoTrenApp(controller: c));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Andén');
  });
}
