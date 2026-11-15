/// Display names that fit on a phone row; Renfe's official names can be long.
const _short = {
  'València-Estació del Nord': 'València Nord',
  'Madrid-Chamartín-Clara Campoamor': 'Chamartín',
};

String shortStopName(String name) {
  final exact = _short[name];
  if (exact != null) return exact;
  var n = name;
  if (n.startsWith('Madrid-')) n = n.substring('Madrid-'.length);
  if (n.endsWith(' Cercanías')) n = n.substring(0, n.length - ' Cercanías'.length);
  return n;
}
