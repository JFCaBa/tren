import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/ui/names.dart';

void main() {
  test('shortens València Nord', () {
    expect(shortStopName('València-Estació del Nord'), 'València Nord');
  });

  test('keeps other names', () {
    expect(shortStopName("L'Alcúdia de Crespins"), "L'Alcúdia de Crespins");
    expect(shortStopName('Silla'), 'Silla');
  });
}
