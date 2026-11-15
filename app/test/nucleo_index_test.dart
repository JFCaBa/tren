import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/nucleo_index.dart';

void main() {
  final index = NucleoIndex.fromJson(
      jsonDecode(File('test/fixtures/index.json').readAsStringSync()) as Map<String, dynamic>);

  test('parses index', () {
    expect(index.generatedAt, DateTime.utc(2026, 11, 15, 3));
    expect(index.nucleos.map((n) => n.id), ['10', '40']);
    expect(index.stops.length, 7);
    final shared = index.stops.firstWhere((s) => s.id == 'X1');
    expect(shared.nucleos, ['10', '40']);
    expect(index.stops.firstWhere((s) => s.id == '64200').lat, closeTo(39.3619548, 1e-9));
  });

  test('looks up nucleo by id', () {
    expect(index.nucleo('40')!.name, 'Valencia');
    expect(index.nucleo('40')!.feedPath, 'feeds/40.json');
    expect(index.nucleo('99'), isNull);
  });

  test('rejects other versions', () {
    expect(() => NucleoIndex.fromJson({'version': 1}), throwsFormatException);
  });
}
