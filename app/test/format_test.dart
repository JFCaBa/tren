import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/ui/departure_row.dart';

void main() {
  test('wait under an hour in minutes', () {
    expect(formatWait(0), 'ahora');
    expect(formatWait(-1), 'ahora'); // board clamps to 0; never show a negative wait
    expect(formatWait(1), '1 min');
    expect(formatWait(59), '59 min');
  });

  test('wait of an hour or more as h:mm', () {
    expect(formatWait(60), '1:00 h');
    expect(formatWait(65), '1:05 h');
    expect(formatWait(500), '8:20 h');
    expect(formatWait(525), '8:45 h');
  });
}
