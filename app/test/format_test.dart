import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/ui/departure_row.dart';

void main() {
  test('wait under an hour in minutes', () {
    expect(formatWait(0), 'ahora');
    expect(formatWait(-1), 'ahora'); // board clamps to 0; never show a negative wait
    expect(formatWait(1), '1 min');
    expect(formatWait(59), '59 min');
  });

  test('line text is dark on light line colors', () {
    expect(lineTextColor(0xFFFFD700), 0xFF000000); // yellow (Madrid C5)
    expect(lineTextColor(0xFFC6D300), 0xFF000000); // lime (C10)
    expect(lineTextColor(0xFF0D3386), 0xFFFFFFFF); // dark blue
    expect(lineTextColor(0xFFF79529), 0xFF000000); // Valencia C2 orange: black 9.1:1 vs white 2.3:1
    expect(lineTextColor(0xFF7AB3DE), 0xFF000000); // Valencia C1 light blue
    expect(lineTextColor(0xFFE30613), 0xFFFFFFFF); // red
  });

  test('wait of an hour or more as h:mm', () {
    expect(formatWait(60), '1:00 h');
    expect(formatWait(65), '1:05 h');
    expect(formatWait(500), '8:20 h');
    expect(formatWait(525), '8:45 h');
  });
}
