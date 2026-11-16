import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/domain/train.dart';

void main() {
  test('train number comes from a Renfe trip id, same rule as the pipeline', () {
    expect(trainNumber('3019L23525C1'), '23525');
    expect(trainNumber('1017S27616C8b'), '27616');
    expect(trainNumber('SPECIAL_10_91217C3'), isNull);
    expect(trainNumber('T1'), isNull);
  });
}
