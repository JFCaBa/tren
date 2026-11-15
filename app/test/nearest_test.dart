import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/feed.dart';
import 'package:proximotren/domain/nearest.dart';

void main() {
  const stops = [
    Stop(id: '65000', name: 'València Nord', lat: 39.4669305, lon: -0.3772239),
    Stop(id: '64200', name: 'Silla', lat: 39.3619548, lon: -0.4149813),
    Stop(id: '69110', name: 'Gandia', lat: 38.9705140, lon: -0.1797829),
  ];

  test('picks closest stop', () {
    final (stop, meters) = nearestStop(stops, 39.3630, -0.4140);
    expect(stop.id, '64200');
    expect(meters, lessThan(500));
    expect(meters, greaterThan(50));
  });
}
