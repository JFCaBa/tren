/// Display names that fit on a phone row; Renfe's official names can be long.
const _short = {'València-Estació del Nord': 'València Nord'};

String shortStopName(String name) => _short[name] ?? name;
