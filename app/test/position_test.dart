import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/domain/position.dart';

void main() {
  const stops = [('10000', 'Chamartín'), ('18000', 'Atocha'), ('18002', 'Getafe Centro'), ('18101', 'Mine')];

  test('where texts match the server', () {
    expect(whereText(stops, '18101', (stopId: '18000', status: 'STOPPED_AT')), 'En Atocha · a 2 paradas');
    expect(whereText(stops, '18101', (stopId: '18002', status: 'IN_TRANSIT_TO')), 'Hacia Getafe Centro · a 1 parada');
    expect(whereText(stops, '18101', (stopId: '18002', status: 'INCOMING_AT')), 'Hacia Getafe Centro · a 1 parada');
    expect(whereText(stops, '18101', (stopId: '18101', status: 'INCOMING_AT')), 'Llegando');
    expect(whereText(stops, '18101', (stopId: '18101', status: 'STOPPED_AT')), 'En la estación');
  });

  test('unknown where', () {
    expect(whereText(stops, '18101', null), isNull);
    expect(whereText(stops, '18101', (stopId: '99999', status: 'STOPPED_AT')), isNull);
    expect(whereText(stops, '18002', (stopId: '18000', status: 'STOPPED_AT')), isNull);
    expect(whereText(const [], '18101', (stopId: '18000', status: 'STOPPED_AT')), isNull);
  });

  test('status', () {
    expect(liveStatusText(canceled: false), '');
    expect(liveStatusText(delaySec: 20, canceled: false), 'A su hora');
    expect(liveStatusText(delaySec: 300, canceled: false), 'Retraso 5 min');
    expect(liveStatusText(delaySec: 300, canceled: true), 'Cancelado');
  });

  test('content state', () {
    final s = DateTime.utc(2026, 11, 21, 8, 12);
    expect(contentState(scheduled: s, delaySec: 300, canceled: false, usualPlatform: '2', where: 'Llegando'), {
      'departs': s.millisecondsSinceEpoch ~/ 1000 + 300,
      'status': 'Retraso 5 min',
      'platform': '2',
      'usual': true,
      'where': 'Llegando',
      'cancelled': false,
    });
    final c = contentState(scheduled: s, canceled: true, livePlatform: '4', where: 'x');
    expect(c, {'departs': null, 'status': 'Cancelado', 'platform': '4', 'usual': false, 'where': null, 'cancelled': true});
  });
}
