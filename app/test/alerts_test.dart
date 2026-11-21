import 'package:flutter_test/flutter_test.dart';
import 'package:proximotren/data/alerts.dart';
import 'package:proximotren/domain/alerts.dart';

Map<String, dynamic> alertJson(List<Map<String, dynamic>> alerts) => {
      'header': {'gtfsRealtimeVersion': '2.0', 'timestamp': '1795296563'},
      'entity': [
        for (var i = 0; i < alerts.length; i++) {'id': 'AVISO_$i', 'alert': alerts[i]},
      ],
    };

Map<String, dynamic> alert(String text, {List<String> routes = const [], List<String> stops = const [], int? start, int? end}) => {
      'activePeriod': [
        {if (start != null) 'start': '$start', if (end != null) 'end': '$end'},
      ],
      'informedEntity': [
        for (final r in routes) {'routeId': r},
        for (final s in stops) {'stopId': s},
      ],
      'descriptionText': {
        'translation': [
          {'text': text, 'language': 'es'},
        ],
      },
    };

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1795296563 * 1000, isUtc: true);
  const madridLines = {('10', 'C4a'), ('10', 'C3')};

  test('parses the real shape: route ids, stop ids, start, Spanish text', () {
    final a = parseAlerts(alertJson([
      alert('#MadC4a Por reajuste del servicio.\r\n\r\n', routes: ['10T0013C4a', '10T0014C4a'], start: 1795293420),
      alert('Ascensor fuera de servicio.', stops: ['18003'], start: 1795292220),
    ]));
    expect(a, hasLength(2));
    expect(a[0].routeIds, ['10T0013C4a', '10T0014C4a']);
    expect(a[0].start, DateTime.fromMillisecondsSinceEpoch(1795293420 * 1000, isUtc: true));
    expect(a[0].end, isNull);
    expect(a[1].stopIds, ['18003']);
  });

  test('odd entities and missing fields do not throw', () {
    final a = parseAlerts({
      'entity': [
        'x',
        {'id': '1'},
        {'alert': {}},
        {'alert': {'descriptionText': {'translation': [{'text': 'Sin entidades'}]}}},
        {'alert': {'informedEntity': 'nope', 'descriptionText': {'translation': [{'text': '  '}]}}},
      ],
    });
    expect(a.map((e) => e.text), ['Sin entidades']);
    expect(parseAlerts({}), isEmpty);
  });

  test('station alerts by stop id, line alerts by núcleo and line, hashtags stripped', () {
    final a = parseAlerts(alertJson([
      alert('#MadC4a Reajuste en la C4a.', routes: ['10T0013C4a'], start: 1),
      alert('Ascensor de Méndez Álvaro fuera de servicio.', stops: ['18003'], start: 1),
      alert('Obras en la C5.', routes: ['10T0017C5'], start: 1),
      alert('Otra estación.', stops: ['99999'], start: 1),
      alert('Valencia C4a, mismo nombre de línea.', routes: ['40T0001C4a'], start: 1),
    ]));
    final shown = alertsFor(a, stopId: '18003', lines: madridLines, now: now);
    expect(shown, [
      (line: null, text: 'Ascensor de Méndez Álvaro fuera de servicio.'),
      (line: 'C4a', text: 'Reajuste en la C4a.'),
    ]);
  });

  test('a station of two núcleos gets line alerts of both', () {
    final a = parseAlerts(alertJson([
      alert('A', routes: ['10T0001C3'], start: 1),
      alert('B', routes: ['20T0001C1'], start: 1),
    ]));
    final shown = alertsFor(a, stopId: '1', lines: {('10', 'C3'), ('20', 'C1')}, now: now);
    expect(shown.map((s) => s.line), ['C1', 'C3']);
  });

  test('not started yet or already ended: hidden; odd route ids ignored', () {
    final secs = now.millisecondsSinceEpoch ~/ 1000;
    final a = parseAlerts(alertJson([
      alert('Futuro', stops: ['1'], start: secs + 60),
      alert('Pasado', stops: ['1'], start: 1, end: secs - 60),
      alert('Vigente', stops: ['1'], start: 1, end: secs + 60),
      alert('Ruta rara', routes: ['C3', '10X0001C3', ''], start: 1),
    ]));
    expect(alertsFor(a, stopId: '1', lines: madridLines, now: now).map((s) => s.text), ['Vigente']);
  });

  test('the same text on several entities shows once', () {
    final a = parseAlerts(alertJson([
      alert('Igual', routes: ['10T0001C3'], start: 1),
      alert('Igual', routes: ['10T0002C3'], start: 1),
    ]));
    expect(alertsFor(a, stopId: '1', lines: madridLines, now: now), hasLength(1));
  });
}
