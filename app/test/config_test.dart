import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/config.dart';

void main() {
  test('User-Agent carries the major.minor of pubspec (the /anden/admin versions chart)', () {
    final m = RegExp(r'^version:\s*(\d+)\.(\d+)\.', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!;
    expect(userAgent, 'Anden/${m.group(1)}.${m.group(2)}');
  });
}
